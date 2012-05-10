#include "TestSerial.h"

configuration TestSerialAppC {}
implementation {
  components TestSerialC as App, LedsC, MainC;
  components SerialActiveMessageC as AMSerial;
  components ActiveMessageC as AMRadio;
  components new TimerMilliC() as BeaconTimer;
  components new TimerMilliC() as AckTimer;
  components new TimerMilliC() as SensorTimer;
  components LocalTimeSecondC;
  components new SensirionSht11C() as SensorHumidityTemperature;
  components new HamamatsuS1087ParC() as SensorLight;

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
  App.LocalTime -> LocalTimeSecondC;
  App.SensorHumidity -> SensorHumidityTemperature.Humidity;
  App.SensorTemperature -> SensorHumidityTemperature.Temperature;
  App.SensorLight -> SensorLight;
}
