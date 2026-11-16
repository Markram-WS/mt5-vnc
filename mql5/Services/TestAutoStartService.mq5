//+------------------------------------------------------------------+
//|                                      TestAutoStartService.mq5     |
//|                        Copyright 2026, MetaTrader 5               |
//|                                              Version 1.00         |
//|                                        Test Service for auto-start|
//+------------------------------------------------------------------+
#property service
#property description "Test Service for auto-start verification"
#property version   "1.00"

//+------------------------------------------------------------------+
//| Service start function                                            |
//+------------------------------------------------------------------+
int OnStart()
{
   Print("TestAutoStartService: OnStart running");

   // Keep the service alive; a service has no OnTick, so poll once per second.
   while(!IsStopped())
   {
      Print("TestAutoStartService: heartbeat ts=",
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
      Sleep(1000);
   }

   Print("TestAutoStartService: OnStop");
   return(0);
}