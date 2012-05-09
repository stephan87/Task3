#include "TestSerial.h"

configuration TestSerialAppC {}
implementation {
  components TestSerialC as App, LedsC, MainC;
  components SerialActiveMessageC as AMSerial;
  components ActiveMessageC as AMRadio;
  components new TimerMilliC() as BeaconTimer;
  components new TimerMilliC() as AckTimer;
  components new TimerMilliC() as SensorTimer;

  App.Boot -> MainC.Boot;
  
  App.SerialControl  -> AMSerial;
  App.SerialSend 	 -> AMSerial;
  App.SerialReceive  -> AMSerial.Receive;
  App.SerialPacket 	 -> AMSerial;
  App.SerialAMPacket -> AMSerial;
  
  App.RadioControl 	-> AMRadio;
  App.RadioSend 	-> AMRadio;
  App.RadioReceive 	-> AMRadio.Receive;
  App.RadioPacket 	-> AMRadio;
  App.RadioAMPacket -> AMRadio;
  
  App.BeaconTimer -> BeaconTimer;
  App.AckTimer -> AckTimer;
  App.SensorTimer -> SensorTimer;
  App.Leds 	-> LedsC;
}
