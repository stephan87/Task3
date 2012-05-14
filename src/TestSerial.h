#ifndef TEST_SERIAL_H
#define TEST_SERIAL_H

// define SIMULATION if you want to use Tossim, otherwise don't
#define SIMULATION2
#ifdef SIMULATION
#define GETTIME time(NULL)
#else
#define GETTIME call LocalTime.get()
#endif


enum {
  AM_COMMANDMSG 			= 6,		// channel identifier for commands
  AM_BEACONMSG 				= 5,		// channel identifier for beacons
  AM_SENSORMSG				= 4,		// channel identifier for sensormsgs
  AM_TABLEMSG				= 3,		// channel identifier for tablemsgs
  AM_BEACONINTERVAL 		= 2000,		// period in which beacon msgs are sent
  AM_BEACONTIMEOUT			= 15, 		// in seconds
  AM_TABLESIZE 				= 4,		// maximum amount of table entries
  AM_ACKTIMEOUT				= 2000,		// timeout in ms within the acks must be received
  AM_MAXNODEID				= 65535,	// used as default undefined value
  NREADINGS 				= 5, 		// count of sensor reading until transmission
  DEFAULT_SAMPLING_INTERVAL = 1000, 	// Default sensor read interval period.
  SERIAL_ADDR				= 99 		// serial address
};

typedef nx_struct CommandMsg {
  nx_uint16_t seqNum;
  nx_uint16_t ledNum;
  nx_uint16_t sender;
  nx_uint16_t receiver;
  nx_uint8_t sensor[3]; 	//starts or stops reading of 3 sensors
  nx_uint8_t isAck;
} CommandMsg;

typedef nx_struct BeaconMsg {
  nx_uint16_t sender;
} BeaconMsg;

typedef struct MoteTableEntry {
  uint16_t nodeId;
  bool ackReceived;
  uint16_t lastContact;
  bool expired;
  uint16_t seqNumSensor;
  uint16_t seqNumTable;
} MoteTableEntry;

typedef nx_struct SensorMsg {
  nx_uint16_t receiver; 			/* should be serial */
  nx_uint8_t sensor; 				/* From which sensor? 0 means not active*/
  nx_uint16_t interval; 			/* Samping period. */
  nx_uint16_t sender; 				/* Mote id of sending mote. */
  nx_uint16_t seqNum;				/* seq num for the sensor message*/
  nx_uint16_t readings[NREADINGS];	/* "null or error" = 0xffff */
} SensorMsg;

typedef nx_struct TableMsg {
  nx_uint16_t seqNum;
  nx_uint16_t sender; 
  nx_uint8_t receiver; 
  nx_uint16_t nodeId[AM_TABLESIZE];
  nx_uint16_t lastContact[AM_TABLESIZE]; 
} TableMsg;



#endif
