#ifndef TEST_SERIAL_H
#define TEST_SERIAL_H

typedef nx_struct TestSerialMsg {
  nx_uint16_t seqNum;
  nx_uint16_t ledNum;
  nx_uint16_t sender;
  nx_uint16_t receiver;
  nx_uint8_t isAck;
} TestSerialMsg;

typedef nx_struct BeaconMsg {
  nx_uint16_t sender;
} BeaconMsg;

typedef struct MoteTableEntry {
  uint16_t nodeId;
  bool ackReceived;
  uint16_t lastContact;
  bool expired;
} MoteTableEntry;

enum {
  AM_TESTSERIALMSG 	= 6,
  AM_BEACONMSG 		= 5,
  AM_SENDPERIOD 	= 1000,
  AM_BEACONINTERVAL = 2000,
  AM_BEACONTIMEOUT	= 15, // in seconds
  AM_TABLESIZE 		= 10,
  AM_SENDRADIOQ_LEN	= 2,
  AM_ACKTIMEOUT		= 2000,
  AM_MAXNODEID		= 65535,
};

#endif
