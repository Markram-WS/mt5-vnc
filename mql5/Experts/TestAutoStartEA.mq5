//+------------------------------------------------------------------+
//|                                            TestAutoStartEA.mq5    |
//|                        Copyright 2026, MetaTrader 5              |
//|                                              Version 1.00         |
//|                                              Test EA for auto-start|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaTrader 5"
#property version   "1.00"
#property description "Test EA for auto-start verification"

input ulong InpMagic = 12345; // Magic number for position identification

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("TestAutoStartEA: OnInit");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("TestAutoStartEA: OnDeinit");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   Print("TestAutoStartEA: OnTick ts=", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
}
