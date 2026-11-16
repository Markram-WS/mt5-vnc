//+------------------------------------------------------------------+
//|                                                       DXBase.mqh |
//|                             Copyright 2000-2026, MetaQuotes Ltd. |
//|                                                     www.mql5.com |
//+------------------------------------------------------------------+
#include <Object.mqh>
//+------------------------------------------------------------------+
//| Class CDXObjectBase                                              |
//+------------------------------------------------------------------+
class CDXObjectBase : public CObject
  {
protected:
   int               m_context;  
  
public:
   virtual          ~CDXObjectBase(void)
     {
      CObject *next=Next();
      CObject *prev=Prev();
      //--- exclude themself from a list
      if(CheckPointer(next))
         next.Prev(prev);
      if(CheckPointer(prev))
         prev.Next(next);
     }
  };
//+------------------------------------------------------------------+
