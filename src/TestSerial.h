#ifndef TEST_SERIAL_H
#define TEST_SERIAL_H

typedef nx_struct TestSerialMsg {
  nx_uint16_t seqNum;
  nx_uint16_t ledNum;
  nx_uint16_t sender;
  nx_uint16_t receiver;
} TestSerialMsg;

typedef nx_struct BeaconMsg {
  nx_uint16_t sender;
} BeaconMsg;

typedef nx_struct MoteTableEntry {
  nx_uint16_t nodeId;
  nx_uint8_t ackReceived;
  nx_uint16_t lastContact;
} MoteTableEntry;

enum {
  AM_TESTSERIALMSG 	= 6,
  AM_BEACONMSG 		= 7,
  AM_SENDPERIOD 	= 1000,
  AM_BEACONINTERVAL = 2000,
  AM_BEACONTIMEOUT	= 15000,
  AM_TABLESIZE 		= 10,
};

#endif
