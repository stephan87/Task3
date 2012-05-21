#include "TestSerial.h"


module TestSerialC @safe()
{
	uses {
	    interface Boot;
	    interface SplitControl as SerialControl;
	    interface SplitControl as RadioControl;
	
	    interface AMSend as SerialSend[am_id_t id];
	    interface Receive as SerialReceive[am_id_t id];
	    interface Packet as SerialPacket;
	    interface AMPacket as SerialAMPacket;
	    
	    interface AMSend as RadioSend[am_id_t id];
	    interface Receive as RadioReceive[am_id_t id];
	    interface Packet as RadioPacket;
	    interface AMPacket as RadioAMPacket;
	
		interface Timer<TMilli> as BeaconTimer;
		interface Timer<TMilli> as AckTimer;
		interface Timer<TMilli> as SensorTimer;
	    
#ifndef SIMULATION
	    interface LocalTime<TSecond>;
#endif
	    interface Leds;
	    
	    interface Read<uint16_t> as SensorHumidity;
	    interface Read<uint16_t> as SensorTemperature;
	    interface Read<uint16_t> as SensorLight;
	    
	    interface Queue<message_t *> as RadioQueue;
	    interface Pool<message_t> as RadioMsgPool;
	//    interface CC2420Packet;
	    interface Random;
	    interface PacketAcknowledgements;
  	}
}
implementation
{

	uint16_t localSeqNumberCommand = 0; ///< stores the msg sequence number
	uint16_t localSeqNumberSensor = 0;
	uint16_t localSeqNumberTable = 0;

	
	uint16_t tableSendCounter = 0;
	bool radioBusy	= FALSE;
	bool serialBusy	= FALSE;
	bool nodeBusy 	= FALSE;
	message_t sndSerial; 		///< stores the current sent message over serial
	message_t rcvSerial; 		///< stores the current received message over serial
	message_t sndRadio; 		///< stores the current sent message over radio
	message_t sndRadioLast;		///< stores the last sent radio message -  used for retransmit
	message_t rcvRadio; 		///< stores the current received message over radio
	message_t beacon; 			///< stores the current beacon message
	message_t sndSensor; 		///< stores the current sent message over radio
	message_t rcvSensor; 		///< stores the current received message over radio
	message_t tableMsg;			///< stores the current sent table message
	message_t tableMsgSerial;	///< stores the sent serial message for Node 0
	message_t sndSensorSerial;	///< stores the sent sensor message for Node 0
	
	MoteTableEntry neighborTable[AM_TABLESIZE];		///< stores the neighbors of the node
		
	SensorMsg SensorHumidityMsg; 		// collects sensor data to send ... sensor = 1
	SensorMsg SensorTemperatureMsg; 	// collects sensor data to send ... sensor = 2
	SensorMsg SensorLightMsg; 			// collects sensor data to send ... sensor = 3
	
	// counts the sensor readings
	uint8_t readingCountSensorHumidity;
	uint8_t readingCountSensorTemperature;
	uint8_t readingCountSensorLight;
	
	// initialization methods
	void initNeighborTable();
	
	// routing
	uint16_t localHops 	= 0xffff; 	// lower is better
	uint16_t localAvgRSSI 	= 0;	// higher is better
	uint16_t chosenParent 	= 0xffff; // 0xffff = no parent 
	uint16_t localVersion 	= 0xffff; // not set
	
	// methods which capsulate the sending of messages
  	void radioSend(CommandMsg* msgToSend);
  	void enqBeacon();
  	void serialSend();
  	void forwardTable(TableMsg* msg); 
  	void sendRadioAck();
  	void enqTable();
  	void radioSendSensorMsg(SensorMsg *msg);
  	void serialSendSensorMsg(SensorMsg *msg);
  	void serialSendTable(TableMsg* msg);
  	
  	// methods which use sensors 
  	void startSensorTimer();
  	void initSensors();
  	void activateSensor(uint8_t sensor);
  	void deactivateSensor(uint8_t sensor);
  	
  	task void sendQueueTask();
  	void enqAck();
  	message_t sendbuf;
  	int seqNums[10];
  	int seqSensors[10];
	
	// other methods
  	bool isChild(uint16_t moteId);
  	
  	/*
  	*	Method which is called after the Mote booted
  	*	-initializes sensors and neighbor table
  	*	-start periodic sending of beacon messages
  	*/
  	event void Boot.booted() 
  	{	
    	call RadioControl.start();
    	if(TOS_NODE_ID == 0)
    	{
    		call SerialControl.start();
    		// routing... new version
    		localVersion = call Random.rand16(); 
    		localHops = 0; 	// lower is better
			localAvgRSSI = 255;		// higher is better
			chosenParent = 0; // 0xffff = no parent 
   		}
    	
    	initNeighborTable();
    	initSensors();
    	
    	//if(message_t)
    	{
    		dbg("TestSerialC","message length: SensorMsg =%d\n",sizeof(SensorMsg));
    		dbg("TestSerialC","message length: CommandMsg = %d\n",sizeof(CommandMsg));
    		dbg("TestSerialC","message length: TableMsg = %d\n",sizeof(TableMsg));
    		dbg("TestSerialC","message length: BeaconMsg = %d\n",sizeof(BeaconMsg));
    		dbg("TestSerialC","message length: message_t = %d\n",sizeof(message_t));
    	}
    	
    	call BeaconTimer.startPeriodic( AM_BEACONINTERVAL );
  	}
  	
  	task void sendQueueTask()
  	{
  		if(radioBusy){
  			//dbg("TestSerialC","Queue: busy radio->return\n");
  			return;
  		}
  		if(call RadioQueue.empty() == FALSE)
  		{
  			message_t *qMsg = call RadioQueue.dequeue();
  			uint8_t type = *(uint8_t*)(call RadioPacket.getPayload(qMsg, sizeof (uint8_t)));
  			int msgLen = 0;
  		
  			
  		//	am_id_t stype = call RadioAMPacket.type(qMsg);
  		//	am_addr_t src = call RadioAMPacket.source(qMsg);
  		//	am_addr_t dest = call RadioAMPacket.destination(qMsg);
  			am_addr_t receiver = AM_BROADCAST_ADDR;
  			
  			//dbg("TestSerialC","Queue: enqueued element with type %d\n",type);
  			  			
  			switch(type)
  			{
				case AM_BEACONMSG:
				{
					BeaconMsg *sent = (BeaconMsg*)(call RadioPacket.getPayload(qMsg, sizeof (BeaconMsg))); // jump to starting pointer
					msgLen = sizeof(BeaconMsg);
					receiver = AM_BROADCAST_ADDR;
					//dbg("TestSerialC","Queue: Start sending BeaconMsg\n");
					memcpy(&sndRadioLast,sent,msgLen);
					break;
				}
				case AM_SENSORMSG:
				{
					SensorMsg *sent = (SensorMsg*)(call RadioPacket.getPayload(qMsg, sizeof (SensorMsg))); // jump to starting pointer
					msgLen = sizeof(SensorMsg);
					receiver = chosenParent;
					call PacketAcknowledgements.requestAck(qMsg);
					
					//dbg("TestSerialC","Queue: Start sending SensorMsg\n");
					memcpy(&sndRadioLast,sent,msgLen);
					break;
				}
				case AM_TABLEMSG:
				{
					TableMsg *sent = (TableMsg*)(call RadioPacket.getPayload(qMsg, sizeof (TableMsg))); // jump to starting pointer
					msgLen = sizeof(TableMsg);
					receiver = chosenParent; //AM_BROADCAST_ADDR;
					call PacketAcknowledgements.requestAck(qMsg);
					
					//dbg("TestSerialC","Queue: Start sending TableMsg from %d to %d\n",sent->sender,sent->receiver);
					//dbg("TestSerialC","Queue: receiver: %d sndRadio-sender: %d\n",sent->receiver,sent->sender);
					memcpy(&sndRadioLast,sent,msgLen);
					break;
				}
				case AM_COMMANDMSG:
				{
					CommandMsg *sent = (CommandMsg*)(call RadioPacket.getPayload(qMsg, sizeof (CommandMsg))); // jump to starting pointer
					msgLen = sizeof(CommandMsg);
					//dbg("TestSerialC","Queue: Start sending CommandMsg\n");
					//dbg("TestSerialC","Queue: receiver: %d sndRadio-sender: %d sndRadio-ack: %d\n",sent->receiver,sent->sender, sent->isAck);
					memcpy(&sndRadioLast,sent,msgLen);
					if(sent->isAck)
						receiver = sent->receiver;
					else
						receiver = AM_BROADCAST_ADDR;
					break;
				}
  			}
  			if (call RadioSend.send[type](receiver, qMsg, msgLen) != SUCCESS) {
  			 	dbg("TestSerialC","Error Sending");
  			}
  			else{
  				radioBusy = TRUE;
  			}
  		}
  		else
  		{
  			//dbg("TestSerialC","Queue: no element in the queue\n");
  		}
  	}
  	
  	/*
  	*	initializes the neighbor table with default values:
  	*	
  	*/
  	void initNeighborTable()
  	{
  		int i;
  		for(i = 0;i<AM_TABLESIZE;i++)
  		{
  			neighborTable[i].nodeId 		= AM_MAXNODEID;
  			neighborTable[i].ackReceived 	= FALSE;
			neighborTable[i].lastContact	= 0;
		  	neighborTable[i].expired		= FALSE;
   		}
  	}
  	
  	/*******************************************************************************
  	*
  	*							Timers
  	*
  	*******************************************************************************/
  	
  	/*
  	 * Starts timer with DEFAULT_SAMPLING_INTERVAL to read sensors.
  	 */
  	void startSensorTimer() {
    	call SensorTimer.startPeriodic(DEFAULT_SAMPLING_INTERVAL);
    }
        
    
    /* At each sample period:
     - if local sample buffer is full, send accumulated samples
     - read next sample
  	*/
    event void SensorTimer.fired()
    {	
    	// collected all data for this msg?
    	if(readingCountSensorHumidity == NREADINGS)
    	{
    	 	// send message if radio is free , reset readings
    	 	if(TOS_NODE_ID == 0)
    	 	{
				serialSendSensorMsg(&SensorHumidityMsg);
			}
			else
			{
				radioSendSensorMsg(&SensorHumidityMsg);
				SensorHumidityMsg.seqNum = localSeqNumberSensor++;
				
			}
			
			// reset count
			readingCountSensorHumidity = 0;
				   	
    	}
    	if(readingCountSensorTemperature == NREADINGS)
    	{
    		// send message if radio is free , reset readings
    	 	if(TOS_NODE_ID == 0)
    	 	{
				serialSendSensorMsg(&SensorTemperatureMsg);
			}
			else
			{
				radioSendSensorMsg(&SensorTemperatureMsg);
				SensorTemperatureMsg.seqNum = localSeqNumberSensor++;
				
			}
			
			// reset count
			readingCountSensorTemperature = 0;
				   		
    	}
    	if(readingCountSensorLight == NREADINGS)
    	{
    	 	// send message if radio is free , reset readings
    	 	if(TOS_NODE_ID == 0)
    	 	{
				serialSendSensorMsg(&SensorLightMsg);
			}
			else
			{
				radioSendSensorMsg(&SensorLightMsg);
				SensorLightMsg.seqNum = localSeqNumberSensor++;
				
			}
		
			// reset count
			readingCountSensorLight = 0;
				   	
    	}
    	
    	// call read of sensor if sensor is active
    	if(SensorHumidityMsg.sensor == 1)
    	{
    		call SensorHumidity.read();
    	}
    	
    	if(SensorTemperatureMsg.sensor == 2)
    	{
    	
#ifndef SIMULATION
    		call SensorTemperature.read();
#endif
    	}
    	
    	if(SensorLightMsg.sensor == 3)
    	{
    	
#ifndef SIMULATION
    		call SensorLight.read();
#endif	
    	}
    } 
  	
  	/*
  	*	gets fired when a new beacon broadcast needs to be send
  	*/
  	event void BeaconTimer.fired()
  	{
  		enqBeacon();
  		if( tableSendCounter==2 )
	 			{
	 				enqTable(); 
	 				tableSendCounter = 0;
	 			}
	 			else
	 			{
	 				tableSendCounter++;
	 	}
  	}
  	
  	/*
  	*	gets fired when the timout for receiving acknowledgements from neighbors must be finished
  	*/
  	event void AckTimer.fired()
  	{
  		int i;
  		bool needRetransmit = FALSE;
  		
  		//dbg("Routing","############################ Ack fired\n");
  		for(i=0;i<AM_TABLESIZE;i++)
  		{
  			MoteTableEntry *curEntry = &neighborTable[i];
  			
  			if(curEntry->nodeId != AM_MAXNODEID)
  			{
  				dbg("Routing","Table: Node: %d expired: %d ackReceived: %d\n",curEntry->nodeId,curEntry->expired, curEntry->ackReceived);
  				// either the node which got a cmd message isn't present any more or the acknowledgement wasn't received correctly
	  			if(curEntry->expired || !curEntry->ackReceived)
	  			{
	  				needRetransmit = TRUE;
	  				
	  				if(curEntry->expired)
	  				{
	  					curEntry->nodeId = AM_MAXNODEID;
	  					curEntry->lastContact = 0;
	  					curEntry->expired = FALSE;
	  					curEntry->parentMote = 0xffff;
  						curEntry->childMote = FALSE;
  						curEntry->hops = 0xffff;
  						curEntry->avgRSSI = 0;
	  				}
	  				else
	  				{
	  					//dbg("Routing", "ack timer fired but not expired!\n", curEntry->nodeId);
	  				}
	  				
	  			}
	  		}
	  		else
	  		{
	  			//dbg("Routing", "no entry found!\n");
	  		}
  		}
  		
  		if(needRetransmit)
  		{	
  			//retransmit
  			//dbg("TestSerialC","need retransmit\n");
  			radioSend((CommandMsg*)&rcvRadio);
  		}
  		else
  		{
  			dbg("TestSerialC","successfully got all acks\n");
  		}
  	}
  	
  	
	// event which gets fired after the radio control is initialized
  	event void RadioControl.startDone(error_t error) {
    	if (error == SUCCESS) {
    		//dbg("TestSerialC","start done\n");
    	}
  	}
	
	// event which gets fired after the serial control is initialized
  	event void SerialControl.startDone(error_t error) {
    	if (error == SUCCESS) {
    		//dbg("TestSerialC","start done\n");
    	}
  	}

  	event void SerialControl.stopDone(error_t error) {}
  	event void RadioControl.stopDone(error_t error) {}
  
  	/*
  	*	This function receives messages received over the radio
	*	forwards all messages which are not targeted to the current node
	*	The message id distinguishes the different message types @see AM_TABLEMSG, AM_COMMANDMSG, AM_SENSORMSG
  	*/
  	event message_t *RadioReceive.receive[am_id_t id](message_t *msg, void *payload, uint8_t len)
  	{
  		//dbg("TestSerialC","received msg on channel %d\n",id);
  		if(id == AM_BEACONMSG && (sizeof(BeaconMsg)==len))
  		{
  			BeaconMsg *msgReceived;
  			int16_t freeSlot = -1;
  			uint16_t i;
  			bool found = FALSE;
  			uint16_t avgRssiOfSender; 
  			
  			msgReceived = (BeaconMsg*)payload;
  			
  			//calculate avgRSSI
  			avgRssiOfSender = 55;//(call CC2420Packet.getRssi(msg)) / (msgReceived->hops + 1); 
  			
  			
  			// when received a beacon add an entry to the neighbour table and ack
  			for(i=0;i<AM_TABLESIZE;i++)
  			{
  				MoteTableEntry *curEntry = &neighborTable[i];
  				if((curEntry->lastContact == 0))
  				{
  					if(freeSlot == -1)
  					{
  						freeSlot = i;
  						//dbg("TestSerialC","set free slot to: %d\n",freeSlot);
  					}
  				}
  				else
  				{
  					// if there is a entry already there for this node -> update the timestamp
  					if(curEntry->nodeId == msgReceived->sender)
  					{
  						found = TRUE;
  						curEntry->lastContact = GETTIME; // time(NULL); // returns seconds
  						curEntry->parentMote = msgReceived->parent;
  						//dbg("Routing","Received Beacon from %d, parent=%d, hops=%d\n",msgReceived->sender, msgReceived->parent,msgReceived->hops);
  						if(msgReceived->parent == TOS_NODE_ID) // mote has selected my mote as parent
  						{
  							curEntry->childMote = TRUE;
  						}
  						else
  						{
  							curEntry->childMote = FALSE;
  						}
  						curEntry->hops = msgReceived->hops;
  						curEntry->avgRSSI = msgReceived->avgRSSI;
  						
  						//dbg("TestSerialC","curEntry->nodeID: %d found entry for node: %d in neighbor table - update time\n",curEntry->nodeId,msgReceived->sender);
  					}
  					// otherwise delete the node in the table when the timelimit AM_BEACONTIMEOUT is reached
  					else
  					{
  						uint16_t timediff = (GETTIME - curEntry->lastContact) ; // (time(NULL) - curEntry->lastContact);
  						if(timediff > AM_BEACONTIMEOUT)
  						{
  							//dbg("TestSerialC","removed node %d from neighbor table - timediff: %d\n",curEntry->nodeId,timediff);
  							curEntry->expired = TRUE;
  							//if(!nodeBusy)
  							{
  								// connection  to parent is lost ... route failure... reset parent and broadcast lost connection
			  					if(curEntry->nodeId == chosenParent)
			  					{	
			  						dbg("Routing", "######### Connection to mote %d lost!\n", curEntry->nodeId);
			  						localHops = 0xffff; 	// lower is better
			 						localAvgRSSI = 0;	    // higher is better
			 						chosenParent = 0xffff; 	// 0xffff = no parent 
			 						localVersion = call Random.rand16();
			 						if(localVersion == UNDEFINED) localVersion--;
			 						//call Leds.set(0);
			 						enqBeacon();
			  					}
			  					
  								curEntry->nodeId = AM_MAXNODEID;
  								curEntry->lastContact = 0;
  								curEntry->parentMote = UNDEFINED;
		  						curEntry->childMote = FALSE;
		  						curEntry->hops = UNDEFINED;
		  						curEntry->avgRSSI = 0;
  							}
  						}
  					}
  				}
  			}
  			if(freeSlot == -1){
  				//dbg("TestSerialC","found NO free entry in neighbor table\n");
  			}
  			// freier slot gefunden
  			else{
  				// aber kein bereits vorhandener knoteneintrag
  				if(!found)
  				{
  					//dbg("TestSerialC","create new entry on position: %d for node %d\n",freeSlot,msgReceived->sender);
  					neighborTable[freeSlot].nodeId = msgReceived->sender;
  					neighborTable[freeSlot].lastContact = GETTIME; //time(NULL);
  					neighborTable[freeSlot].parentMote = msgReceived->parent;
  					if(msgReceived->parent == TOS_NODE_ID) // mote has selected my mote as parent
  					{
  						neighborTable[freeSlot].childMote = TRUE;
  					}
  					else
  					{
  						neighborTable[freeSlot].childMote = FALSE;
  					}
  					neighborTable[freeSlot].hops = msgReceived->hops;
  					neighborTable[freeSlot].avgRSSI = msgReceived->avgRSSI;
  				}
  			}
  			
  			//****************************************************************************************
  			//
  			//									choose parent
  			//
  			//****************************************************************************************
  			
  			
  			//always update route if msg from parent
  			if(msgReceived->sender == chosenParent)
  			{
  				dbg("Routing","######## msg received from parent: sender=%d, senderParent=%d\n",msgReceived->sender, msgReceived->parent);
  				//new parent
  				if(msgReceived->parent == 0xffff)
  				{
  					chosenParent = 0xffff;
  					localVersion = msgReceived->version;
  					localAvgRSSI = 0;
  					localHops = 0xffff;
  				}
  				else
  				{
  				
	  				localVersion = msgReceived->version;
	  				localAvgRSSI = msgReceived->avgRSSI + avgRssiOfSender;
	  				localHops 	 = msgReceived->hops + 1;
	  			}		
  				// broadcast new info
  				enqBeacon();
  			}
  			//update route if necessary
  			
  			if((msgReceived->parent != TOS_NODE_ID) && (msgReceived->parent != 0xffff)) //&&  // msg not from child, avoids loops
  			{
  				if((msgReceived->hops + 1 < localHops) || // better hopCount
  						((msgReceived->hops+1 == localHops) && ((msgReceived->avgRSSI + avgRssiOfSender) < localAvgRSSI) ))	//same hopCount but better RSSI?
  				{
  					dbg("Routing","update routing information: msgReceived->sender=%d,msgReceived->parent=%d, msgReceived->version=%d, localVersion=%d , hopsMsg=%d, localhops=%d\n",msgReceived->sender,msgReceived->parent,msgReceived->version,localVersion, msgReceived->hops,localHops);
  					//new parent
  					chosenParent = msgReceived->sender;
  					localVersion = msgReceived->version;
  					localAvgRSSI = msgReceived->avgRSSI + avgRssiOfSender;
  					localHops 	 = msgReceived->hops + 1;
  					
  					// broadcast new info
  					enqBeacon();
  				}
  			}
  			return msg;
  		}
  		//dbg("TestSerialC","received msg on channel %d\n",id);
  		// got the right message to cast ?
  		if ((id == AM_COMMANDMSG) && (len == sizeof(CommandMsg)))
  		{
    		CommandMsg *msgReceived;
  			memcpy(&rcvRadio,payload,len);
    		msgReceived = (CommandMsg*)&rcvRadio;
    		//dbg("TestSerialC","Node %d received msg for %d from %d isAck: %d\n",TOS_NODE_ID,msgReceived->receiver,msgReceived->sender,msgReceived->isAck);
    		
			if(msgReceived->receiver == TOS_NODE_ID)
			{
				if(msgReceived->isAck)
				{
					int i;
					//dbg("TestSerialC","Node %d received Ack from: %d\n",TOS_NODE_ID,msgReceived->sender);
					for(i=0;i<AM_TABLESIZE;i++)
					{
						// update the neighbor table and set ackReceived to TRUE
						MoteTableEntry *curEntry = &neighborTable[i];
						if(curEntry->nodeId == msgReceived->sender)
						{
							curEntry->ackReceived = TRUE;
							break;
						}
					}
					return msg;
				}
    			else if(msgReceived->seqNum > localSeqNumberCommand)
    			{
    				int i;
    				dbg("TestSerialC","Finished Node %d: received message on RadioChannel seqNum: %d\n",TOS_NODE_ID,msgReceived->seqNum);
    				localSeqNumberCommand = msgReceived->seqNum;
    			    //	call Leds.set(msgReceived->ledNum);
    				for(i=0;i<3;i++)
    				{
    					// activate the sensors which are specified by the sensor field in the command message
    					if(msgReceived->sensor[i] == 1)
    					{
    						activateSensor(i+1);
    					}
    					else
    					{
    						deactivateSensor(i+1);
    					}
    				}
    				// enable/disable led
    				call Leds.set(msgReceived->ledNum);
    			}
    			else
    			{
	    			dbg("TestSerialC","Node %d:duplicate message received from %d\n",TOS_NODE_ID,msgReceived->sender);
	    		}
	    		//post sendRadioAck();
				enqAck();
				post sendQueueTask();
	    	}
	    	else
	    	{	
	    		if(msgReceived->seqNum > localSeqNumberCommand)
	    		{
	    			localSeqNumberCommand = msgReceived->seqNum;
    				radioSend(msgReceived);
    			}
    			//post sendRadioAck();
	    		enqAck();
	    		post sendQueueTask();
    		}
		}
		if((id == AM_TABLEMSG) && (len == sizeof(TableMsg)))
		{
			TableMsg* curMsg = (TableMsg*)payload;
			am_addr_t source;
			// if its node 0 then send over serial to pc, if not forward the message
			curMsg = (TableMsg*)payload;
			source = call RadioAMPacket.source(msg);
			//dbg("TestSerialC","received tablemsg over radio from source: %d, sender: %d\n",source,curMsg->sender);
			
				
			// entry found?
			//if(searchedTableEntryIndex != 0xffff)
			{
				// check seqNum
				if(curMsg->seqNum > seqNums[curMsg->sender])
				{
					if(TOS_NODE_ID == 0)
					{
						
						//dbg("TestSerialCSerial","forward table message from %d to serial parent: %d\n",curMsg->sender,curMsg->parent);
						//curMsg->seqNum = curMsg->seqNum + 1;
						serialSendTable((TableMsg*)curMsg);
					}
					else
					{
						if(curMsg->sender != TOS_NODE_ID)
						{
							if(isChild(source))
							{
								forwardTable((TableMsg*)curMsg);
								// update seqNum
								//neighborTable[searchedTableEntryIndex].seqNumTable = curMsg->seqNum;
							
								//dbg("TestSerialC","forward table message from %d to %d\n",curMsg->sender,curMsg->receiver);
							}
							else
							{
								//dbg("Routing","Routing: No table msg forwarded from node: %d \n",curMsg->sender);
							}
						}
					}
					seqNums[curMsg->sender] = curMsg->seqNum;
				}
				else
				{
					//dbg("TestSerialC","Seq no conflict!!! seqReceived: %d, seqInTable: %d\n",curMsg->seqNum,seqNums[curMsg->sender]);
				}
			}
			//else
			{
				//dbg("TestSerialC","no entry in neighbor table found for table message forwarding\n");
			}
		}
		// if we have received a SensorMsg then check for correct seq numbers and forward the message if neccessary
		if((id == AM_SENSORMSG) && (len == sizeof(SensorMsg)))
		{	
			SensorMsg* curMsg = (SensorMsg*)payload;
			am_addr_t source = call RadioAMPacket.source(msg);
			
			//dbg("TestSerialC","received tablemsg over radio\n");
			// if its node 0 then send over serial to pc, if not forward the message
			
			//if(searchedSensorEntryIndex != 0xffff)
			{
				// check seqNum
				if(curMsg->seqNum > seqSensors[curMsg->sender])
				{
					if(TOS_NODE_ID == 0)
					{
			
						dbg("TestSerialCSensor","node 0 received sensor data - forward to serial\n");
						serialSendSensorMsg((SensorMsg*)curMsg);
						
					}
					else
					{
						dbg("TestSerialC","forward Sensor message from %d to %d\n",curMsg->sender,curMsg->receiver);
						if(isChild(source))
						{
							radioSendSensorMsg((SensorMsg*)curMsg);
						}
					}
					// update seqNum
					seqSensors[curMsg->sender] = curMsg->seqNum;
				}
				else
				{
					//dbg("TestSerialC","Seq no conflict!!! seqReceived: %d, seqInTable: %d\n",curMsg->seqNum,seqSensors[curMsg->sender]);
				}
			}
		}
    	return msg;
  	}
  	
  	/*
  	*	Forwards a certain message on the Serial Port -  applies only to Node 0
  	*/
  	void serialSendTable(TableMsg* msg)
  	{
  		if(!serialBusy)
  		{
			int i;
			TableMsg* msgToSend = (TableMsg*)(call SerialPacket.getPayload(&tableMsgSerial, sizeof (TableMsg)));
			msgToSend->sender = msg->sender;
			msgToSend->receiver = msg->receiver;
			msgToSend->parent = msg->parent;
			
			for(i=0;i<AM_TABLESIZE;i++)
			{
				msgToSend->nodeId[i] = msg->nodeId[i];
				msgToSend->lastContact[i] = msg->lastContact[i];
				//dbg("TestSerialC","before sending over serial nodeId: %d lastContact: %d\n",msgToSend->nodeId[i],msgToSend->lastContact[i]);
			}
					
			// forward message
			if(call SerialSend.send[AM_TABLEMSG](msg->receiver,&tableMsgSerial, sizeof(TableMsg)) == SUCCESS)
			{
				serialBusy = TRUE;
				//dbg("TestSerialC","serial reflect\n");
			}
		}
		else{
			dbg("TestSerialC","serialBusy\n");
		}
  	}
  	
  	/*
  	*	sends an acknowledgement to the sender of the last received command
  	*/
  	void enqAck()
  	{
  		CommandMsg* lastMsg;
  		message_t *newmsg;
  		CommandMsg* msgToSend;
  		
		lastMsg = (CommandMsg*)&rcvRadio;
		//CommandMsg* sent = (CommandMsg*)&sndRadio;
		newmsg = call RadioMsgPool.get();
		
		
		msgToSend = (CommandMsg*)(call RadioPacket.getPayload(newmsg, sizeof (CommandMsg)));
		//dbg("TestSerialC","got ack msg from pool\n");
		//dbg("TestSerialC","override sndRadio\n");
		//dbg("TestSerialC","send radio ack -> sndRadio-recv: %d sndRadio-sender: %d sndRadio-ack: %d\n",sent->receiver,sent->sender, sent->isAck);

		msgToSend->sender = TOS_NODE_ID;
		msgToSend->seqNum = lastMsg->seqNum;
		msgToSend->ledNum = lastMsg->ledNum;
		msgToSend->receiver = lastMsg->sender;
		msgToSend->isAck = 1;
		msgToSend->type = AM_COMMANDMSG;

		

		//dbg("TestSerialC","send ack to: %d from %d\n",lastMsg->sender,TOS_NODE_ID);
		
		if (call RadioQueue.enqueue(newmsg) != SUCCESS)
		{
			dbg("TestSerialC","couldnt enqueue msg\n");
		}
  	}
  	
	/*
	*	Sends the received message from pc directly back to the pc (used as a message received indication)
	*/
  	void serialSend() 
  	{	
		// is radio unused?
		if(!serialBusy){
			CommandMsg* msgReceived = (CommandMsg*)&rcvSerial;			
			CommandMsg* msgToSend = (CommandMsg*)(call SerialPacket.getPayload(&sndSerial, sizeof (CommandMsg)));
			msgToSend->sender = TOS_NODE_ID;
			msgToSend->seqNum = msgReceived->seqNum;
			msgToSend->ledNum = msgReceived->ledNum;
			msgToSend->receiver = msgReceived->sender;
			msgToSend->isAck = TRUE;
		
			// forward message
			if(call SerialSend.send[AM_COMMANDMSG](msgReceived->sender,&sndSerial, sizeof(CommandMsg)) == SUCCESS){
				serialBusy = TRUE;
				//dbg("TestSerialC","serial reflect\n");
			}
		}
		else{
			dbg("TestSerialC","serialBusy\n");
		}
  	}
  	
  	/*
  	*	Event which is fired after a transmit of a message over the serial channel
  	*/
  	event void SerialSend.sendDone[am_id_t id](message_t* msg, error_t error)
  	{
	    if (error == SUCCESS)
	    {
		// has the sent message the right pointer
	      	//if(&sndSerial == msg)
	      	{
	      		//dbg("TestSerialCSend", "send done: serial on id %d\n",id);
	      		serialBusy = FALSE;
	      		//call Leds.led1Toggle();
	      		return;
	      	}
	    }
  		dbg("TestSerialC", "error on message pointer\n");
  	}
  	
  	/*
  	*	Event which is fired when a certain message was received over the serial channel
  	*	reflects the received message to the gui application indication successful reception
  	*	and forwads the received command over radio
  	*/
  	event message_t *SerialReceive.receive[am_id_t id](message_t *msg, void *payload, uint8_t len)
  	{  	
  		dbg("TestSerialC","received message on serial channel\n");	
  		// got the right message to cast ?
  		if (len == sizeof(CommandMsg))
  		{
    		CommandMsg *msgReceived;
  			memcpy(&rcvSerial,payload,len);
    		msgReceived = (CommandMsg*)&rcvSerial;
    		    		
    		// check sequence number to avoid sending of duplicates
    		if(msgReceived->seqNum > localSeqNumberCommand)
    		{
    			localSeqNumberCommand=msgReceived->seqNum;
    			
    			if(msgReceived->receiver == TOS_NODE_ID)
    			{
    				
    				int i;
	    			//dbg("TestSerialC","Finished Node %d: received message on RadioChannel seqNum: %d\n",TOS_NODE_ID,msgReceived->seqNum);
	    			localSeqNumberCommand = msgReceived->seqNum;
	    			//	call Leds.set(msgReceived->ledNum);
	    			for(i=0;i<3;i++)
	    			{
	    				if(msgReceived->sensor[i] == 1)
	    				{
	    					activateSensor(i+1);
	    				}
	    				else
	    				{
	    					deactivateSensor(i+1);
	    				}
	    			}
	    			//send a CommandMsg over the serial Channel
    				serialSend();
    			}
    			else
    			{
	    			// is radserialSend();io unused?
	    			if(!radioBusy)
	    			{   			
						CommandMsg* msgToSend = (CommandMsg*)(call RadioPacket.getPayload(&sndRadio, sizeof (CommandMsg)));
						msgToSend->sender = TOS_NODE_ID;
						msgToSend->seqNum = msgReceived->seqNum;
						msgToSend->ledNum = msgReceived->ledNum;
						msgToSend->receiver = msgReceived->receiver;
						msgToSend->sensor[0] = msgReceived->sensor[0];
						msgToSend->sensor[1] = msgReceived->sensor[1];
						msgToSend->sensor[2] = msgReceived->sensor[2];
						msgToSend->isAck = 0; 
						
						memcpy(&sndRadioLast,msgToSend,sizeof(CommandMsg));
						
						// forward message
						if(call RadioSend.send[AM_COMMANDMSG](AM_BROADCAST_ADDR,&sndRadio, sizeof(CommandMsg)) == SUCCESS)
						{
							//dbg("TestSerialC", "message sent - msgToSend->isAck: %d, receiver: %d\n", msgToSend->isAck, msgToSend->receiver);
							radioBusy = TRUE;
							serialSend();
						}
					}
					else
					{
						dbg("TestSerialC","radioBusy!\n");
					}
				}
    		}
  		}	  		
  		return msg;
  	}
  	
  	/*
  	*	Sends a CommandMsg over Radio
  	*
  	*	@param CommandMsg to send
  	*/
  	void radioSend(CommandMsg *receivedMsgToSend)
  	{
  		message_t *newMsg;
  		CommandMsg* msgToSend;
  		
		// is radio unused?
  		newMsg = call RadioMsgPool.get();
		
		msgToSend = (CommandMsg*)(call RadioPacket.getPayload(newMsg, sizeof (CommandMsg)));
		memcpy(msgToSend,receivedMsgToSend,sizeof(CommandMsg));
		msgToSend->sender = TOS_NODE_ID;
		msgToSend->type = AM_COMMANDMSG;
		/*
		msgToSend->seqNum = receivedMsgToSend->seqNum;
		msgToSend->ledNum = receivedMsgToSend->ledNum;
		msgToSend->receiver = receivedMsgToSend->receiver;
		msgToSend->isAck = 0;
		msgToSend->type = AM_COMMANDMSG;
		*/
		
		//dbg("TestSerialC","got cmd forward msg from pool\n");
		
		if (call RadioQueue.enqueue(newMsg) != SUCCESS)
		{
			dbg("TestSerialC","couldnt enqueue Command msg\n");
		}
		else
		{
			//dbg("TestSerialC","enqueued new beacon msg\n");
			post sendQueueTask();
		}
  	}

 	/*
  	*	Sends a BeaconMsg over Radio via broadcast
  	*/
  	void enqBeacon()
  	{
  		message_t *newMsg;
  		BeaconMsg* msgToSend;

  		newMsg = call RadioMsgPool.get();
		msgToSend = (BeaconMsg*)(call RadioPacket.getPayload(newMsg, sizeof (BeaconMsg)));
		msgToSend->sender = TOS_NODE_ID;
		msgToSend->type = AM_BEACONMSG;
		msgToSend->hops = localHops;
		msgToSend->avgRSSI = localAvgRSSI;
		msgToSend->version = localVersion;
		msgToSend->parent = chosenParent;
		
		//dbg("TestSerialC","got beacon msg from pool\n");
		
		if (call RadioQueue.enqueue(newMsg) != SUCCESS)
		{
			dbg("TestSerialC","couldnt enqueue beacon msg\n");
		}
		else
		{
			//dbg("TestSerialC","enqueued new beacon msg\n");
			post sendQueueTask();
		}
  	}
  	
  	/*
  	*	Task to forward table message to other nodes
  	*/
  	void enqTable()
  	{
		int i;
		message_t *newMsg;
		TableMsg* msgToSend;
		
		if(msgToSend == NULL || chosenParent == UNDEFINED)
		{
			dbg("TestSerialC","null pointer on msg struct\n");
			return;
		}
		
		newMsg = call RadioMsgPool.get();
		msgToSend = (TableMsg*)(call RadioPacket.getPayload(newMsg, sizeof (TableMsg)));
		//dbg("TestSerialC","got table msg from pool\n");
		
		msgToSend->sender = TOS_NODE_ID;
		msgToSend->receiver = 99;
		msgToSend->seqNum = ++localSeqNumberTable;
		msgToSend->type = AM_TABLEMSG;
		msgToSend->parent = chosenParent;
		
		//dbg("TestSerialC","start sending tableMsg\n");
		
		for(i=0;i<AM_TABLESIZE;i++)
		{
			//dbg("TestSerialC","fill no %d: nodeId: %d lastCont: %d\n",i,neighborTable[i].nodeId,neighborTable[i].lastContact);
			msgToSend->nodeId[i] = neighborTable[i].nodeId;
			msgToSend->lastContact[i] = neighborTable[i].lastContact;
		}
		//dbg("TestSerialC","after filling tableMsg\n");
		
		if(TOS_NODE_ID == 0)
		{
			serialSendTable(msgToSend);
			// important to free memory
			if(call RadioMsgPool.put(newMsg) != SUCCESS)
			{
				dbg("TestSerialC","couldn't free table memory after serial send\n");
			}
			// forward message broadcast
		}
		else
		{
			if (call RadioQueue.enqueue(newMsg) != SUCCESS)
			{
				dbg("TestSerialC","couldnt enqueue table msg\n");
			}
			else
			{
				//dbg("TestSerialC","enqueued new table msg\n");
				post sendQueueTask();
			}
		}
  	}
  	
  	/*
  	*	sends a certain TableMsg over the radio channel via broadcast
  	*
  	*	@param TableMsg to send over radio
  	*/
  	void forwardTable(TableMsg* msg)
  	{
  		message_t* newMsg;
  		TableMsg* tblMsg;
  		if(chosenParent == UNDEFINED)
		{
			dbg("Routing","no parent - do not send tableMsg\n");
			return;
		}
		newMsg = call RadioMsgPool.get();
		tblMsg = call RadioPacket.getPayload(newMsg, sizeof (TableMsg));
		memcpy(tblMsg,msg,sizeof(TableMsg));
	
		tblMsg->type = AM_TABLEMSG;

		//dbg("TestSerialC","enqueue forwarded table message from pool\n");

		if (call RadioQueue.enqueue(newMsg) != SUCCESS)
		{
			dbg("TestSerialC","couldnt enqueue forwarded table msg\n");
		}
		else{
			post sendQueueTask();
		}
	
  	}
  	
  	/*
  	*	Event which gets fired after successful/failed transmission of a message over radio
  	*/
  	event void RadioSend.sendDone[am_id_t id](message_t* msg, error_t error)
  	{
    	if (error != SUCCESS)
    	{
    		dbg("TestSerialC","Error: Node %d couldnt send message on RadioChannel\n",TOS_NODE_ID);
    	}
    	else
    	{
    		//dbg("TestSerialC","send done for ch id: %d\n",id);
    		if(id == AM_COMMANDMSG)
    		{
    			CommandMsg* sentMsg;
    			//dbg("TestSerialC","sent CommandMsg\n");
	    		if(TOS_NODE_ID == 0)
	    		{
	    			//call Leds.led0Toggle();
	    		}
 			
	 			// start a timer within all neighbors in the table must acknowledge the receival
	 			sentMsg = (CommandMsg*)&sndRadioLast;
	 			//dbg("TestSerialC","SendDone: sentMsg->isAck: %d, receiver: %d, sender: %d\n",sentMsg->isAck,sentMsg->receiver,sentMsg->sender);
	 			if(!sentMsg->isAck)
	 			{
	 				//dbg("TestSerialC","send done for normal message-> start timer\n");
	 				call AckTimer.startOneShot( AM_ACKTIMEOUT );
	 			}
	 		}else if(id == AM_BEACONMSG)
	 		{
	 			//dbg("TestSerialC","sent BeaconMsg\n");
	 			
	 		}
	 		else if(id == AM_TABLEMSG)
			{
				bool acked;
	 			TableMsg* sentMsg;
	 			sentMsg = (TableMsg*)&sndRadioLast;
	 			
	 			acked = call PacketAcknowledgements.wasAcked(msg);
	 			if(!acked)
	 			{
	 				dbg("Acked","retransmit tableMsg %d\n",acked);
	 				forwardTable((TableMsg*)&sndRadioLast);
	 			}
			}
			else if(id == AM_SENSORMSG)
			{
				bool acked;
				acked = call PacketAcknowledgements.wasAcked(msg);
	 			if(!acked)
	 			{
	 				dbg("Acked","retransmit sensorMsg %d\n",acked);
	 				radioSendSensorMsg((SensorMsg*)&sndRadioLast);
	 			}
			}
		}
		radioBusy = FALSE;
		if(call RadioMsgPool.put(msg) == SUCCESS)
		{
			//dbg("Pool","elements in pool: %d\n",(call RadioMsgPool.size()));
		}
		else
		{
			dbg("TestSerialC","could't free elements");
		}
		post sendQueueTask();
  	}
  	
  	/*******************************************************************************
  	*
  	*				Sensors: init, activate, read and SensorMsg forwarding
  	*
  	********************************************************************************/


	/*
     * Activates sensors by parameter sensor and activates timer
     * SensorHumidity = 1
     * SensorTemperature = 2
     * SensorLight = 3
     * @param sensor activates sensor 1-3.
     */
     void activateSensor(uint8_t sensor)
     {
     	dbg("TestSerialCSensor","activate sensor %d\n",sensor);
     	if(sensor == 1)
     	{
     		SensorHumidityMsg.sensor = 1;	
     	}
     	if(sensor == 2)
     	{
     		SensorTemperatureMsg.sensor = 2;	
     	}
     	if(sensor == 3)
     	{
     		SensorLightMsg.sensor = 3;	
     	}
     	
     	startSensorTimer();	
     }
     
     /*
     * Deactivates sensors by parameter sensor.
     * SensorHumidity = 1
     * SensorTemperature = 2
     * SensorLight = 3
     * @param sensor deactivates sensor 1-3.
     */
     void deactivateSensor(uint8_t sensor)
     {
     	dbg("TestSerialCSensor","deactivate sensor %d\n",sensor);
     	if(sensor == 1)
     	{
     		SensorHumidityMsg.sensor = 0;	
     	}
     	if(sensor == 2)
     	{
     		SensorTemperatureMsg.sensor = 0;	
     	}
     	if(sensor == 3)
     	{
     		SensorLightMsg.sensor = 0;	
     	}	
     }
     
     /*
     * Inits all sensors messages and readingCounts.
     */
     void initSensors()
     {
     	int i;
     	dbg("TestSerialCSensor","initSensors\n");
     	
     	SensorHumidityMsg.interval 	= DEFAULT_SAMPLING_INTERVAL;
    	SensorHumidityMsg.sender 	= TOS_NODE_ID;
    	SensorHumidityMsg.receiver 	= SERIAL_ADDR;
    	SensorHumidityMsg.sensor 	= 0;
    	SensorHumidityMsg.seqNum 	= 1;
    	SensorHumidityMsg.count 	= NREADINGS;
    	SensorHumidityMsg.version 	= 0;
                 	
     	SensorTemperatureMsg.interval 	= DEFAULT_SAMPLING_INTERVAL;
    	SensorTemperatureMsg.sender 	= TOS_NODE_ID;
    	SensorTemperatureMsg.receiver 	= SERIAL_ADDR;
    	SensorTemperatureMsg.sensor 	= 0;	
    	SensorTemperatureMsg.seqNum 	= 1;
    	SensorTemperatureMsg.count 	= NREADINGS;
    	SensorTemperatureMsg.version 	= 0;
         	
     	SensorLightMsg.interval 	= DEFAULT_SAMPLING_INTERVAL;
    	SensorLightMsg.sender 		= TOS_NODE_ID;
    	SensorLightMsg.receiver 	= SERIAL_ADDR;
    	SensorLightMsg.sensor 		= 0;	
      	SensorLightMsg.seqNum 		= 1;
      	SensorLightMsg.count 		= NREADINGS;
      	SensorLightMsg.version 		= 0;
     	
     	// initialize the sensor readind data
  		for(i = 0; i < NREADINGS; i++)
  		{
  			SensorHumidityMsg.readings[i] = 0xffff;
  		}
     	
     	for(i = 0; i < NREADINGS; i++)
  		{
  			SensorTemperatureMsg.readings[i] = 0xffff;
  		}
     	
     	for(i = 0; i < NREADINGS; i++)
  		{
  			SensorLightMsg.readings[i] = 0xffff;
  		}
  		
  		
  		readingCountSensorHumidity = 0;
		readingCountSensorTemperature = 0;
		readingCountSensorLight = 0;
  			
     }
  	
  	/*
  	*	Gets data from sensor.
  	* 	Writes data into the message.
  	*	If reading was not successful then data = 0xffff.
  	*/
  	event void SensorHumidity.readDone(error_t result, uint16_t data) {
  		
  		// successful?
	    if (result != SUCCESS)
	    {
			data = 0xffff;
	    }
	    
	    // add data to message
	    if (readingCountSensorHumidity < NREADINGS)
	    { 
	      	SensorHumidityMsg.readings[readingCountSensorHumidity++] = data;
	  	}
  	}
  	
  	
  	/*
  	*	Gets data from sensor.
  	* 	Writes data into the message.
  	*	If reading was not successful then data = 0xffff.
  	*/
  	event void SensorTemperature.readDone(error_t result, uint16_t data) {
  		
  		// successful?
	    if (result != SUCCESS)
	    {
			data = 0xffff;
	    }
	    
	    // add data to message
	    if (readingCountSensorTemperature < NREADINGS)
	    { 
	      	SensorTemperatureMsg.readings[readingCountSensorTemperature++] = data;
	  	}
  	}
  	
  	/*
  	*	Gets data from sensor.
  	* 	Writes data into the message.
  	*	If reading was not successful then data = 0xffff.
  	*/
  	event void SensorLight.readDone(error_t result, uint16_t data) {
  		
  		// successful?
	    if (result != SUCCESS)
	    {
			data = 0xffff;
	    }
	    
	    // add data to message
	    if (readingCountSensorLight < NREADINGS)
	    { 
	      	SensorLightMsg.readings[readingCountSensorLight++] = data;
	  	}
  	}
  	
  	/*
  	*	Sends a SensorMsg over serial.
  	* 	@param inputMsg SensorMsg pointer to message which should be sent.
  	*/
  	void serialSendSensorMsg(SensorMsg *msg)
  	{
  		dbg("TestSerialCSensor","send sensor data over serial\n");
  		if(!serialBusy)
  		{
			SensorMsg* msgToSend = (SensorMsg*)(call SerialPacket.getPayload(&sndSensorSerial, sizeof (SensorMsg)));
  			memcpy(msgToSend,msg,sizeof(SensorMsg));
		
			// forward or send message
			if(call SerialSend.send[AM_SENSORMSG](SERIAL_ADDR,&sndSensorSerial, sizeof(SensorMsg)) == SUCCESS){
				serialBusy = TRUE;
				dbg("TestSerialCSensor","send serial sensor data successful\n");
			}
		}
		else{
			dbg("TestSerialCSensor","serialBusy\n");
		}
  	}
  	
  	/*
  	*	Sends a SensorMsg over radio.
  	*	@param receivedMsgToSend pointer to received message
  	*/
  	void radioSendSensorMsg(SensorMsg* msg)
  	{
		message_t *newMsg;
  		SensorMsg* sensorMsg;
  		if(chosenParent == UNDEFINED)
  		{
  			dbg("Routing","wont forward sensor msg -> no parent node\n");
  			return;
  		}
  		
		newMsg = call RadioMsgPool.get();
		sensorMsg = call RadioPacket.getPayload(newMsg, sizeof (SensorMsg));
		memcpy(sensorMsg,msg,sizeof(SensorMsg));
		sensorMsg->type = AM_SENSORMSG;
		
		dbg("TestSerialCSensor","radio send sensor start\n");
	
		//dbg("TestSerialCSensor","got sensor msg from pool\n");
		// forward or send message
		if (call RadioQueue.enqueue(newMsg) != SUCCESS)
		{
			dbg("TestSerialC","couldnt enqueue forwarded table msg\n");
		}
		else{
			post sendQueueTask();
		}
  	}
  	/*
  	*	Searches for an entry of the neighborTable by moteId.  
  	*	@param moteId id of the searched index
  	*	@return TRUE if mote is child
  	*/
  	bool isChild(uint16_t moteId)
  	{
  		int i;
  		
  		dbg("Routing","Routing: search for nodeId: %d in table children -> currentParent: %d\n",moteId,chosenParent);
  		for(i = 0 ; i < AM_TABLESIZE; i++)
  		{
  			dbg("Routing","table[%d].nodeId=%d, isChild %d\n",i,neighborTable[i].nodeId,neighborTable[i].childMote);
  			if((neighborTable[i].nodeId == moteId) && (neighborTable[i].childMote == TRUE))
  			{
  				return TRUE;
  			}
  		}
  		return FALSE;
  	}
} 
