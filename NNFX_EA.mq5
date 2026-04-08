//+------------------------------------------------------------------+
//|                                                     NNFX_EA.mq5 |
//|                         No Nonsense Forex Algorithm EA for MT5  |
//|                                                                  |
//| Architecture:                                                    |
//|   - Baseline   : EMA (configurable period)                       |
//|   - C1         : Stochastic (configurable) – primary entry      |
//|   - C2         : RSI (configurable) – confirmation filter        |
//|   - Volume     : ATR-based volatility gate                       |
//|   - Exit       : Awesome Oscillator zero-cross (configurable)   |
//|   - ATR        : Stop-loss/take-profit sizing                    |
//|                                                                  |
//| All indicator "slots" expose input parameters so they can be    |
//| replaced with any indicator that returns a buffer value.        |
//+------------------------------------------------------------------+
#property copyright "NNFX EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//────────────────────────────────────────────────────────────────────
// Input Parameters
//────────────────────────────────────────────────────────────────────

// ── Risk Management ──────────────────────────────────────────────
input double   RiskPercent      = 2.0;    // Risk % per trade
input double   ATR_SL_Mult      = 1.5;   // ATR multiplier for stop loss
input double   ATR_TP_Mult      = 1.0;   // ATR multiplier for take profit (Banker order)
input double   ATR_BEOffset     = 0.1;   // Extra ATR to add to break-even price (buffer)
input int      MagicNumber      = 202600; // EA magic number

// ── ATR Settings ─────────────────────────────────────────────────
input int      ATR_Period       = 14;    // ATR period

// ── Baseline: EMA ────────────────────────────────────────────────
input int      Baseline_Period  = 20;    // Baseline EMA period
input double   Baseline_MaxDist = 1.0;  // Max distance from baseline in ATR ("A Bridge Too Far")

// ── C1: Stochastic ───────────────────────────────────────────────
// Bullish signal when %K crosses above %D below oversold level
// Bearish signal when %K crosses below %D above overbought level
input int      C1_KPeriod       = 5;
input int      C1_DPeriod       = 3;
input int      C1_Slowing       = 3;
input double   C1_Oversold      = 20.0;
input double   C1_Overbought    = 80.0;

// ── C2: RSI ──────────────────────────────────────────────────────
// Bullish when RSI > 50, Bearish when RSI < 50
input int      C2_Period        = 14;
input double   C2_BullThresh    = 50.0;  // RSI must be above this for long
input double   C2_BearThresh    = 50.0;  // RSI must be below this for short

// ── Volume/Volatility: ATR gate ───────────────────────────────────
// Trade only when ATR > MinATR_Pips (filters dead/flat markets)
input double   Vol_MinATR_Pips  = 30.0;  // Minimum ATR in pips to allow entry

// ── Exit: Awesome Oscillator Zero-Cross ──────────────────────────
// Close Runner when AO crosses zero against the trade
input int      Exit_AO_Fast     = 5;
input int      Exit_AO_Slow     = 34;

// ── Trade Session Filter ─────────────────────────────────────────
// Only process new candle logic; no session filter on Daily
input bool     AllowLong        = true;
input bool     AllowShort       = true;

//────────────────────────────────────────────────────────────────────
// Globals
//────────────────────────────────────────────────────────────────────
CTrade         trade;
CPositionInfo  pos;

// Indicator handles
int hATR       = INVALID_HANDLE;
int hBaseline  = INVALID_HANDLE;
int hC1_K      = INVALID_HANDLE;
int hC2_RSI    = INVALID_HANDLE;
int hExit_AO   = INVALID_HANDLE;

datetime lastBarTime = 0;

// Order tracking (magic number encodes role: Banker = MagicNumber, Runner = MagicNumber+1)
const long MAGIC_BANKER = MagicNumber;
const long MAGIC_RUNNER = MagicNumber + 1;

//────────────────────────────────────────────────────────────────────
// EA Lifecycle
//────────────────────────────────────────────────────────────────────
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber); // Will be overridden per order

   hATR      = iATR(_Symbol, PERIOD_D1, ATR_Period);
   hBaseline = iMA(_Symbol, PERIOD_D1, Baseline_Period, 0, MODE_EMA, PRICE_CLOSE);
   hC1_K     = iStochastic(_Symbol, PERIOD_D1, C1_KPeriod, C1_DPeriod, C1_Slowing, MODE_SMA, STO_LOWHIGH);
   hC2_RSI   = iRSI(_Symbol, PERIOD_D1, C2_Period, PRICE_CLOSE);
   hExit_AO  = iAO(_Symbol, PERIOD_D1);

   if(hATR == INVALID_HANDLE || hBaseline == INVALID_HANDLE ||
      hC1_K == INVALID_HANDLE || hC2_RSI == INVALID_HANDLE ||
      hExit_AO == INVALID_HANDLE)
   {
      Print("NNFX EA: Failed to create one or more indicator handles.");
      return INIT_FAILED;
   }

   Print("NNFX EA initialised on ", _Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hATR);
   IndicatorRelease(hBaseline);
   IndicatorRelease(hC1_K);
   IndicatorRelease(hC2_RSI);
   IndicatorRelease(hExit_AO);
}

void OnTick()
{
   // ── Only act on new Daily candle ─────────────────────────────
   datetime currentBarTime = iTime(_Symbol, PERIOD_D1, 0);
   if(currentBarTime == lastBarTime)
   {
      // Between candles: manage open positions (break-even, exit)
      ManageOpenPositions();
      return;
   }
   lastBarTime = currentBarTime;

   // ── New candle: gather indicator values from the CLOSED bar [1] ─
   double atr       = GetBuffer(hATR,      0, 1);
   double baseline  = GetBuffer(hBaseline, 0, 1);
   double baseline_2 = GetBuffer(hBaseline, 0, 2); // baseline two bars ago (one-candle rule)
   double c1_k_now  = GetBuffer(hC1_K,     0, 1); // %K current
   double c1_k_prev = GetBuffer(hC1_K,     0, 2); // %K previous
   double c1_k_2ago = GetBuffer(hC1_K,     0, 3); // %K two bars ago (one-candle rule)
   double c1_d_now  = GetBuffer(hC1_K,     1, 1); // %D current
   double c1_d_prev = GetBuffer(hC1_K,     1, 2); // %D previous
   double c1_d_2ago = GetBuffer(hC1_K,     1, 3); // %D two bars ago (one-candle rule)
   double rsi       = GetBuffer(hC2_RSI,   0, 1);
   double closeD1   = iClose(_Symbol, PERIOD_D1, 1);
   double closeD1_2 = iClose(_Symbol, PERIOD_D1, 2); // close two bars ago (one-candle rule)

   if(atr == EMPTY_VALUE || baseline == EMPTY_VALUE) return;

   // ── Volume / Volatility Gate ──────────────────────────────────
   double atrPips = atr / GetPipSize();
   if(atrPips < Vol_MinATR_Pips)
   {
      // Market too quiet – do not enter new trades
      return;
   }

   // ── Check for existing positions; only one set at a time ──────
   bool bankerOpen = PositionExists(MAGIC_BANKER);
   bool runnerOpen = PositionExists(MAGIC_RUNNER);

   // ── Baseline Direction ─────────────────────────────────────────
   // One-candle rule: accept if price was on the correct side of the
   // baseline on either of the last two closed candles.
   bool priceAboveBaseline = (closeD1 > baseline) || (closeD1_2 > baseline_2);
   bool priceBelowBaseline = (closeD1 < baseline) || (closeD1_2 < baseline_2);

   // ── "A Bridge Too Far" filter ─────────────────────────────────
   double distanceFromBaseline = MathAbs(closeD1 - baseline);
   bool tooFarFromBaseline = (distanceFromBaseline > atr * Baseline_MaxDist);

   // ── C1: Stochastic Cross ──────────────────────────────────────
   // One-candle rule: cross is valid if it occurred on candle [1] or [2].
   // Bullish: %K crossed above %D on candle [1] (between [2]→[1])
   //       or on candle [2] (between [3]→[2])
   bool c1_bull = ((c1_k_prev < c1_d_prev) && (c1_k_now  >= c1_d_now))   // cross on [1]
               || ((c1_k_2ago < c1_d_2ago) && (c1_k_prev >= c1_d_prev)); // cross on [2]
   // Bearish: %K crossed below %D on candle [1] or [2]
   bool c1_bear = ((c1_k_prev > c1_d_prev) && (c1_k_now  <= c1_d_now))   // cross on [1]
               || ((c1_k_2ago > c1_d_2ago) && (c1_k_prev <= c1_d_prev)); // cross on [2]

   // ── C2: RSI Filter ───────────────────────────────────────────
   bool c2_bull = (rsi > C2_BullThresh);
   bool c2_bear = (rsi < C2_BearThresh);

   // ── Entry Logic ──────────────────────────────────────────────
   // Note: AO is the EXIT indicator only – not used for entry
   if(!bankerOpen && !runnerOpen)
   {
      if(AllowLong && priceAboveBaseline && !tooFarFromBaseline
         && c1_bull && c2_bull)
      {
         OpenNNFXTrade(ORDER_TYPE_BUY, atr);
      }
      else if(AllowShort && priceBelowBaseline && !tooFarFromBaseline
              && c1_bear && c2_bear)
      {
         OpenNNFXTrade(ORDER_TYPE_SELL, atr);
      }
   }
}

//────────────────────────────────────────────────────────────────────
// Open the two NNFX orders (Banker + Runner)
//────────────────────────────────────────────────────────────────────
void OpenNNFXTrade(ENUM_ORDER_TYPE direction, double atr)
{
   double price    = (direction == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                   : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist   = atr * ATR_SL_Mult;
   double tpDist   = atr * ATR_TP_Mult;
   double pipSize  = GetPipSize();

   double sl, tp_banker;
   if(direction == ORDER_TYPE_BUY)
   {
      sl         = price - slDist;
      tp_banker  = price + tpDist;
   }
   else
   {
      sl         = price + slDist;
      tp_banker  = price - tpDist;
   }

   // ── Calculate lot size for 2% risk ───────────────────────────
   double lots = CalcLotSize(slDist, RiskPercent);
   if(lots <= 0.0) return;

   // Split equally between Banker and Runner
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double halfLot = NormalizeLots(lots / 2.0, minLot, lotStep);
   if(halfLot < minLot) halfLot = minLot;

   // ── Banker order (has TP) ─────────────────────────────────────
   trade.SetExpertMagicNumber(MAGIC_BANKER);
   bool bankerOK = (direction == ORDER_TYPE_BUY)
                   ? trade.Buy(halfLot, _Symbol, price, sl, tp_banker, "NNFX Banker")
                   : trade.Sell(halfLot, _Symbol, price, sl, tp_banker, "NNFX Banker");

   if(!bankerOK)
      Print("NNFX: Banker order failed – ", trade.ResultRetcodeDescription());

   // ── Runner order (no TP, managed by exit indicator) ──────────
   trade.SetExpertMagicNumber(MAGIC_RUNNER);
   bool runnerOK = (direction == ORDER_TYPE_BUY)
                   ? trade.Buy(halfLot, _Symbol, price, sl, 0.0, "NNFX Runner")
                   : trade.Sell(halfLot, _Symbol, price, sl, 0.0, "NNFX Runner");

   if(!runnerOK)
      Print("NNFX: Runner order failed – ", trade.ResultRetcodeDescription());

   if(bankerOK || runnerOK)
      Print("NNFX: Opened ", EnumToString(direction), " | Lots:", halfLot,
            " | SL dist:", DoubleToString(slDist / pipSize, 1), " pips",
            " | ATR:", DoubleToString(atr / pipSize, 1), " pips");
}

//────────────────────────────────────────────────────────────────────
// Manage open positions: break-even and exit logic
//────────────────────────────────────────────────────────────────────
void ManageOpenPositions()
{
   double ao_now  = GetBuffer(hExit_AO, 0, 1);
   double ao_prev = GetBuffer(hExit_AO, 0, 2);
   double atr     = GetBuffer(hATR,     0, 1);

   // ── Check if Banker is still open or already closed ──────────
   bool bankerOpen = PositionExists(MAGIC_BANKER);
   bool runnerOpen = PositionExists(MAGIC_RUNNER);

   if(!runnerOpen) return; // Nothing to manage

   // ── Break-even: move Runner SL to BE when Banker TP was hit ──
   if(!bankerOpen && runnerOpen)
   {
      MoveRunnerToBreakEven(atr);
   }

   // ── Exit: close Runner on AO zero-cross against position ─────
   if(runnerOpen)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!pos.SelectByIndex(i)) continue;
         if(pos.Magic() != MAGIC_RUNNER) continue;
         if(pos.Symbol() != _Symbol) continue;

         bool isBuy  = (pos.PositionType() == POSITION_TYPE_BUY);
         bool isSell = (pos.PositionType() == POSITION_TYPE_SELL);

         // AO crosses zero against the trade
         bool exitLong  = isBuy  && (ao_prev >= 0.0) && (ao_now < 0.0);
         bool exitShort = isSell && (ao_prev <= 0.0) && (ao_now > 0.0);

         if(exitLong || exitShort)
         {
            trade.SetExpertMagicNumber(MAGIC_RUNNER);
            if(trade.PositionClose(pos.Ticket()))
               Print("NNFX: Runner closed by AO exit signal.");
            else
               Print("NNFX: Runner close failed – ", trade.ResultRetcodeDescription());
         }
      }
   }
}

//────────────────────────────────────────────────────────────────────
// Move the Runner's stop loss to break-even (+ small ATR buffer)
//────────────────────────────────────────────────────────────────────
void MoveRunnerToBreakEven(double atr)
{
   if(atr == EMPTY_VALUE || atr <= 0.0) return;

   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Magic() != MAGIC_RUNNER) continue;
      if(pos.Symbol() != _Symbol) continue;

      double openPrice = pos.PriceOpen();
      double currentSL = pos.StopLoss();
      bool   isBuy     = (pos.PositionType() == POSITION_TYPE_BUY);

      // Normalize bePrice to avoid floating-point mismatch with broker's stored SL
      double bePrice;
      if(isBuy)
      {
         bePrice = NormalizeDouble(openPrice + atr * ATR_BEOffset, _Digits);
         // Guard: already at or past BE (use 1-point tolerance to handle float drift)
         if(currentSL >= bePrice - point) continue;

         // Broker stop-level check: SL must be at least stopLevel below current bid
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(stopLevel > 0.0 && bePrice > bid - stopLevel)
         {
            Print("NNFX: BE price within broker stop level, skipping.");
            continue;
         }
      }
      else
      {
         bePrice = NormalizeDouble(openPrice - atr * ATR_BEOffset, _Digits);
         // Guard: already at or past BE
         if(currentSL <= bePrice + point) continue;

         // Broker stop-level check: SL must be at least stopLevel above current ask
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(stopLevel > 0.0 && bePrice < ask + stopLevel)
         {
            Print("NNFX: BE price within broker stop level, skipping.");
            continue;
         }
      }

      trade.SetExpertMagicNumber(MAGIC_RUNNER);
      if(trade.PositionModify(pos.Ticket(), bePrice, pos.TakeProfit()))
         Print("NNFX: Runner moved to break-even at ", DoubleToString(bePrice, _Digits));
      else
         Print("NNFX: Break-even move failed – ", trade.ResultRetcodeDescription());
   }
}

//────────────────────────────────────────────────────────────────────
// Helpers
//────────────────────────────────────────────────────────────────────

// Read a single value from an indicator buffer (with error guard)
double GetBuffer(int handle, int bufferIndex, int shift)
{
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, bufferIndex, shift, 1, arr) < 1)
      return EMPTY_VALUE;
   return arr[0];
}

// Calculate lot size so that slDistance × lot = RiskPercent% of balance
double CalcLotSize(double slDistance, double riskPercent)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney  = balance * riskPercent / 100.0;
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickSize == 0.0 || tickValue == 0.0) return minLot;

   double slTicks    = slDistance / tickSize;
   double lossPerLot = slTicks * tickValue;
   if(lossPerLot <= 0.0) return minLot;

   double lots = riskMoney / lossPerLot;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return NormalizeLots(lots, minLot, lotStep);
}

// Normalize lot size to broker's volume step
double NormalizeLots(double lots, double minLot, double lotStep)
{
   if(lotStep <= 0.0) return lots;
   lots = MathFloor(lots / lotStep) * lotStep;
   int digits = (int)MathRound(MathLog10(1.0 / lotStep));
   return NormalizeDouble(lots, digits);
}

// Get pip size for the current symbol (handles 3/5-digit brokers)
double GetPipSize()
{
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   // 3 or 5 digit quotes: 1 pip = 10 points
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
}

// Check whether at least one position with the given magic number exists
bool PositionExists(long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Magic() == magic && pos.Symbol() == _Symbol)
         return true;
   }
   return false;
}
//+------------------------------------------------------------------+
