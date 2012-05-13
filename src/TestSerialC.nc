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
		//interface Timer<TMilli> as TableSendTimer;
	    
#ifndef SIMULATION
	    interface LocalTime<TSecond>;
#endif
	    
	    interface Leds;
	    
	    interface Read<uint16_t> as SensorHumidity;
	    interface Read<uint16_t> as SensorTemperature;
	    interface Read<uint16_t> as SensorLight;
	    
  	}
}
implementation
{

	uint16_t localSeqNumber = 0; ///< stores the msg sequence number
	uint16_t localSeqNumberSensor = 0;
	uint16_t localSeqNumberTable = 0;
	uint16_t lastRadioTableMsgSender = 0xffff;
	uint16_t lastRadioSensorMsgSender = 0xffff; // not in use
	uint16_t tableSendCounter = 0;
	bool radioBusy	= FALSE;
	bool serialBusy	= FALSE;
	bool nodeBusy 	= FALSE;
	message_t sndSerial; ///< strores the current sent message over serial
	message_t rcvSerial; ///< strores the current received message over serial
	message_t sndRadio; ///< strores the current sent message over radio
	message_t sndRadioLast;
	message_t rcvRadio; ///< strores the current received message over radio
	message_t beacon; 
	am_addr_t addr;
	message_t sndSensor; // < strores the current sent message over radio
	message_t rcvSensor; // < strores the current received message over radio
	message_t tableMsg;
	message_t tableMsgSerial;
	message_t sndSensorSerial;
	
	uint16_t testCounter = 0;
	MoteTableEntry neighborTable[AM_TABLESIZE];
	message_t radioSendQueue[AM_SENDRADIOQ_LEN];
	
	SensorMsg SensorHumidityMsg; // collects sensor data to send ... sensor = 1
	SensorMsg SensorTemperatureMsg; // collects sensor data to send ... sensor = 2
	SensorMsg SensorLightMsg; // collects sensor data to send ... sensor = 3
	/* 0 to NREADINGS */
	uint8_t readingCountSensorHumidity;
	uint8_t readingCountSensorTemperature;
	uint8_t readingCountSensorLight;
	
	
	
	
	// methods which capsulate the sending of messages
	void serialSend();
  	void radioSend(CommandMsg* msgToSend);
  	void beaconSend();
  	task void tableSendTask(); 
  	void initNeighborTable();
  	task void sendRadioAck();
  	void serialSendTable(TableMsg* msg);
  	void radioSendSensorMsg(SensorMsg *msg);
  	void serialSendSensorMsg(SensorMsg *msg);
  	void radioSendTable(TableMsg* msg);
  	
  	// methods which uses sensors 
  	void startSensorTimer();
  	void initSensors();
  	void activateSensor(uint8_t sensor);
  	void deactivateSensor(uint8_t sensor);
  	
  	
  
  	event void Boot.booted() {
	
    	call RadioControl.start();
    	if(TOS_NODE_ID == 0){
    		call SerialControl.start();
    	}
    	
    	initNeighborTable();
    	initSensors();
    	
    	
    	
#ifdef SIMULATION
    	activateSensor(1);
#endif
    	call BeaconTimer.startPeriodic( AM_BEACONINTERVAL );
    	//call TableSendTimer.startPeriodic(TABLESENDTIMER_INTERVAL);
  	}
  	
  	void initNeighborTable()
  	{
  		int i;
  		for(i = 0;i<AM_TABLESIZE;i++)
  		{
  			neighborTable[i].nodeId = neighborTable[i].nodeId - 1;
  			//dbg("TestSerialC","init: %d\n",neighborTable[i].nodeId);
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
				SensorHumidityMsg.seqNum = localSeqNumberSensor+1;
				
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
				SensorTemperatureMsg.seqNum = localSeqNumberSensor+1;
				
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
				SensorLightMsg.seqNum = localSeqNumberSensor+1;
				
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
  		if(!radioBusy)
		{
			//if(TOS_NODE_ID != 0 || testCounter<=3)
			{
  				beaconSend();
  				//testCounter++;
  			}
		}
  	}
  	
  	/*
  	*	gets fired when the timout for receiving acknowledgements from neighbors must be finished
  	*/
  	event void AckTimer.fired()
  	{
  		//TODO nodeBusy überprüfen wann das notwenig ist
  		int i;
  		bool needRetransmit = FALSE;
  		
  		for(i=0;i<AM_TABLESIZE;i++)
  		{
  			MoteTableEntry *curEntry = &neighborTable[i];
  			
  			if(curEntry->nodeId != AM_MAXNODEID)
  			{
  				dbg("TestSerialC","Table: Node: %d expired: %d ackReceived: %d\n",curEntry->nodeId,curEntry->expired, curEntry->ackReceived);
	  			if(curEntry->expired || !curEntry->ackReceived)
	  			{
	  				needRetransmit = TRUE;
	  				
	  				if(curEntry->expired){
	  					curEntry->nodeId = AM_MAXNODEID;
	  					curEntry->lastContact = 0;
	  					curEntry->expired = FALSE;
	  				}
	  			}
	  		}
  		}
  		
  		if(needRetransmit)
  		{
  			dbg("TestSerialC","need retransmit\n");
  			radioSend((CommandMsg*)&rcvRadio);
  			// TODO retransmit des letzen commandos...
  		}
  		else
  		{
  			dbg("TestSerialC","successfully got all acks\n");
  		}
  	}
  	
  	
  	/*
  	*	Sends table over radio to serial every TABLESENDTIMERT_INTERVAL
  	
  	event void TableSendTimer.fired()
  	{
  		post tableSendTask();
  	
  	}
  	*/
  	
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
  	*/
  	event message_t *RadioReceive.receive[am_id_t id](message_t *msg, void *payload, uint8_t len)
  	{
  		dbg("TestSerialC","received msg on channel %d\n",id);
  		if(id == AM_BEACONMSG && (sizeof(BeaconMsg)==len))
  		{
  			BeaconMsg *msgReceived;
  			int16_t freeSlot = -1;
  			uint16_t i;
  			bool found = FALSE;
  			
  			msgReceived = (BeaconMsg*)payload;
  			
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
  							if(!nodeBusy)
  							{
  								curEntry->nodeId = AM_MAXNODEID;
  								curEntry->lastContact = 0;
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
  				}
  			}
  			return msg;
  		}
  		// got the right message to cast ?
  		 		
  		if ((id == AM_COMMANDMSG) && (len == sizeof(CommandMsg)))
  		{
    		CommandMsg *msgReceived;
  			memcpy(&rcvRadio,payload,len);
    		msgReceived = (CommandMsg*)&rcvRadio;
    		dbg("TestSerialC","Node %d received msg for %d from %d isAck: %d\n",TOS_NODE_ID,msgReceived->receiver,msgReceived->sender,msgReceived->isAck);
    		
			if(msgReceived->receiver == TOS_NODE_ID)
			{
				if(msgReceived->isAck)
				{
					int i;
					dbg("TestSerialC","Node %d received Ack from: %d\n",TOS_NODE_ID,msgReceived->sender);
					for(i=0;i<AM_TABLESIZE;i++)
					{
						MoteTableEntry *curEntry = &neighborTable[i];
						if(curEntry->nodeId == msgReceived->sender)
						{
							curEntry->ackReceived = TRUE;
							break;
						}
					}
					return msg;
				}
    			else if(msgReceived->seqNum > localSeqNumber)
    			{
    				int i;
    				dbg("TestSerialC","Finished Node %d: received message on RadioChannel seqNum: %d\n",TOS_NODE_ID,msgReceived->seqNum);
    				localSeqNumber = msgReceived->seqNum;
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
    			}
    			else
    			{
	    			dbg("TestSerialC","Node %d:duplicate message received from %d\n",TOS_NODE_ID,msgReceived->sender);
	    		}
	    		post sendRadioAck();
	    	}
	    	else
	    	{	
	    		if(msgReceived->seqNum > localSeqNumber)
	    		{
	    			localSeqNumber = msgReceived->seqNum;
    				radioSend(msgReceived);
    			}
    			post sendRadioAck();
    		}
		}
		if((id == AM_TABLEMSG) && (len == sizeof(TableMsg)))
		{
			TableMsg* curMsg = (TableMsg*)payload;
			//dbg("TestSerialC","received tablemsg over radio\n");
			// if its node 0 then send over serial to pc, if not forward the message
			if(TOS_NODE_ID == 0)
			{
							
				dbg("TestSerialC","forward table message from %d to serial\n",curMsg->sender);
				serialSendTable((TableMsg*)curMsg);
				
			}
			else
			{	
				
				curMsg = (TableMsg*)payload;
				if((curMsg->seqNum > localSeqNumberTable) && (curMsg->sender != lastRadioTableMsgSender))
				{
					dbg("TestSerialC","forward table message from %d to %d\n",curMsg->sender,curMsg->receiver);
					radioSendTable((TableMsg*)curMsg);
					lastRadioTableMsgSender = curMsg->sender;
					localSeqNumberTable = curMsg->seqNum;
				}
			}
		}
		
		if((id == AM_SENSORMSG) && (len == sizeof(SensorMsg)))
		{	
			SensorMsg* curMsg = (SensorMsg*)payload;
			//dbg("TestSerialC","received tablemsg over radio\n");
			// if its node 0 then send over serial to pc, if not forward the message
			if(TOS_NODE_ID == 0)
			{
				
				dbg("TestSerialCSensor","node 0 received sensor data - forward to serial\n");
				serialSendSensorMsg((SensorMsg*)curMsg);
				//call Leds.led1Toggle();
			}
			else
			{
				if((curMsg->seqNum > localSeqNumberSensor) && (curMsg->sender != lastRadioSensorMsgSender))
				{
				
					dbg("TestSerialCSensor","node % received sensor data - forward over radio\n",TOS_NODE_ID);
					radioSendSensorMsg((SensorMsg*)curMsg);
					//call Leds.led0Toggle();
					lastRadioSensorMsgSender = curMsg->sender;
					localSeqNumberSensor = curMsg->seqNum;
					
				}
			}
		}
    	return msg;
  	}
  	
  	void serialSendTable(TableMsg* msg)
  	{
  		if(!serialBusy)
  		{
			int i;
			TableMsg* msgToSend = (TableMsg*)(call SerialPacket.getPayload(&tableMsgSerial, sizeof (TableMsg)));
			msgToSend->sender = msg->sender;
			msgToSend->receiver = msg->receiver;
			
			for(i=0;i<AM_TABLESIZE;i++)
			{
				msgToSend->nodeId[i] = msg->nodeId[i];
				msgToSend->lastContact[i] = msg->lastContact[i];
				dbg("TestSerialC","before sending over serial nodeId: %d lastContact: %d\n",msgToSend->nodeId[i],msgToSend->lastContact[i]);
			}
					
			// forward message
			if(call SerialSend.send[AM_TABLEMSG](msg->receiver,&tableMsgSerial, sizeof(TableMsg)) == SUCCESS){
				serialBusy = TRUE;
				//dbg("TestSerialC","serial reflect\n");
			}
		}
		else{
			dbg("TestSerialC","serialBusy\n");
		}
  	}
  	  
  	task void sendRadioAck()
  	{
  		//dbg("TestSerialC","Send Ack to node: %d\n",lastMsg->sender);
  		// is radio unused?
		if(!radioBusy)
		{
			CommandMsg* lastMsg = (CommandMsg*)&rcvRadio;
			//CommandMsg* sent = (CommandMsg*)&sndRadio;
			CommandMsg* msgToSend = (CommandMsg*)(call RadioPacket.getPayload(&sndRadio, sizeof (CommandMsg)));
			//dbg("TestSerialC","override sndRadio\n");
			//dbg("TestSerialC","send radio ack -> sndRadio-recv: %d sndRadio-sender: %d sndRadio-ack: %d\n",sent->receiver,sent->sender, sent->isAck);
			
			msgToSend->sender = TOS_NODE_ID;
			msgToSend->seqNum = lastMsg->seqNum;
			msgToSend->ledNum = lastMsg->ledNum;
			msgToSend->receiver = lastMsg->sender;
			msgToSend->isAck = 1;
			
			memcpy(&sndRadioLast,msgToSend,sizeof(CommandMsg));
			
			dbg("TestSerialC","send ack to: %d from %d\n",lastMsg->sender,TOS_NODE_ID);
			
			// forward message broadcast
			if(call RadioSend.send[AM_COMMANDMSG](lastMsg->sender,&sndRadio, sizeof(CommandMsg)) == SUCCESS)
			{
				radioBusy = TRUE;
			}
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

  	event void SerialSend.sendDone[am_id_t id](message_t* msg, error_t error)
  	{
	    if (error == SUCCESS)
	    {
		// has the sent message the right pointer
	      	//if(&sndSerial == msg)
	      	{
	      		dbg("TestSerialCSend", "send done: serial on id %d\n",id);
	      		serialBusy = FALSE;
	      		//call Leds.led1Toggle();
	      		return;
	      	}
	    }
  		dbg("TestSerialC", "error on message pointer\n");
  	}

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
    		if(msgReceived->seqNum > localSeqNumber)
    		{
    			localSeqNumber=msgReceived->seqNum;
    			
    			if(msgReceived->receiver == TOS_NODE_ID)
    			{
    				
    				int i;
	    			dbg("TestSerialC","Finished Node %d: received message on RadioChannel seqNum: %d\n",TOS_NODE_ID,msgReceived->seqNum);
	    			localSeqNumber = msgReceived->seqNum;
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
							dbg("TestSerialC", "message sent - msgToSend->isAck: %d, receiver: %d\n", msgToSend->isAck, msgToSend->receiver);
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

  	void radioSend(CommandMsg *receivedMsgToSend)
  	{
		// is radio unused?
		if(!radioBusy)
		{		
			CommandMsg* msgToSend = (CommandMsg*)(call RadioPacket.getPayload(&sndRadio, sizeof (CommandMsg)));
			msgToSend->sender = TOS_NODE_ID;
			msgToSend->seqNum = receivedMsgToSend->seqNum;
			msgToSend->ledNum = receivedMsgToSend->ledNum;
			msgToSend->receiver = receivedMsgToSend->receiver;
			msgToSend->isAck = 0;
			
			memcpy(&sndRadioLast,msgToSend,sizeof(CommandMsg));
			
			// forward message broadcast
			if(call RadioSend.send[AM_COMMANDMSG](AM_BROADCAST_ADDR,&sndRadio, sizeof(CommandMsg)) == SUCCESS)
			{
				radioBusy = TRUE;
				dbg("TestSerialC","Node %d forwarded message\n",TOS_NODE_ID);
			}
		}
  	}
  	
  	void beaconSend()
  	{
		// is radio unused?
		if(!radioBusy)
		{	
			BeaconMsg* msgToSend = (BeaconMsg*)(call RadioPacket.getPayload(&beacon, sizeof (BeaconMsg)));
			msgToSend->sender = TOS_NODE_ID;
			
			// forward message broadcast
			if(call RadioSend.send[AM_BEACONMSG](AM_BROADCAST_ADDR,&beacon, sizeof(BeaconMsg)) == SUCCESS)
			{
				radioBusy = TRUE;
				//dbg("TestSerialC","Node %d sent beacon message\n",TOS_NODE_ID);
			}
		}
  	}
  	/*
  	*	Task to forward table message to other nodes
  	*/
  	task void tableSendTask()
  	{
  		if(!radioBusy)
  		{
  			int i;
  			
  			TableMsg* msgToSend = (TableMsg*)(call RadioPacket.getPayload(&tableMsg, sizeof (TableMsg)));
  			
  			if(msgToSend == NULL)
  			{
  				dbg("TestSerialC","null pointer on msg struct\n");
  				return;
  			}
  			msgToSend->sender = TOS_NODE_ID;
  			msgToSend->receiver = 99;
  			msgToSend->seqNum = localSeqNumberTable +1;
  			
  			dbg("TestSerialC","start sending tableMsg\n");
  			
  			for(i=0;i<AM_TABLESIZE;i++)
  			{
  				dbg("TestSerialC","fill no %d: nodeId: %d lastCont: %d\n",i,neighborTable[i].nodeId,neighborTable[i].lastContact);
  				msgToSend->nodeId[i] = neighborTable[i].nodeId;
  				msgToSend->lastContact[i] = neighborTable[i].lastContact;
  			}
  			dbg("TestSerialC","after filling tableMsg\n");
  			
  			if(TOS_NODE_ID == 0)
  			{
  				serialSendTable(msgToSend);
  				// forward message broadcast
  			}else if(call RadioSend.send[AM_TABLEMSG](AM_BROADCAST_ADDR,&tableMsg, sizeof(TableMsg)) == SUCCESS)
			{
				radioBusy = TRUE;
				dbg("TestSerialC","Node %d sent tableMessage message\n",TOS_NODE_ID);
			}
  		}
  	}
  	void radioSendTable(TableMsg* msg)
  	{
  		if(!radioBusy)
  		{
  			TableMsg* tblMsg = call RadioPacket.getPayload(&tableMsg, sizeof (TableMsg));
  			memcpy(tblMsg,msg,sizeof(TableMsg));
  			
  			if(call RadioSend.send[AM_TABLEMSG](AM_BROADCAST_ADDR,&tableMsg, sizeof(TableMsg)) == SUCCESS)
			{
				radioBusy = TRUE;
				dbg("TestSerialC","Node %d forwarded tableMessage message from %d\n",TOS_NODE_ID, msg->sender);
			}
  		}
  	}

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
	    		if(TOS_NODE_ID == 0)
	    		{
	    			call Leds.led0Toggle();
	    		}
 			
	 			// start a timer within all neighbors in the table must acknowledge the receival
	 			sentMsg = (CommandMsg*)&sndRadioLast;
	 			dbg("TestSerialC","sentMsg->isAck: %d, receiver: %d, sender: %d\n",sentMsg->isAck,sentMsg->receiver,sentMsg->sender);
	 			if(!sentMsg->isAck)
	 			{
	 				dbg("TestSerialC","send done for normal message-> start timer\n");
	 				call AckTimer.startOneShot( AM_ACKTIMEOUT );
	 			}
	 		}
	 		if(id == AM_BEACONMSG && (tableSendCounter==6))
	 		{
	 			post tableSendTask(); 
	 			tableSendCounter = 0;
	 		}
	 		else if (id == AM_BEACONMSG )
	 		{
	 		tableSendCounter++;
			}
		}
		radioBusy = FALSE;
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
     	
     	SensorHumidityMsg.interval = DEFAULT_SAMPLING_INTERVAL;
    	SensorHumidityMsg.sender = TOS_NODE_ID;
    	SensorHumidityMsg.receiver = SERIAL_ADDR;
    	SensorHumidityMsg.sensor = 0;
    	SensorHumidityMsg.seqNum = 1;	
                 	
     	SensorTemperatureMsg.interval = DEFAULT_SAMPLING_INTERVAL;
    	SensorTemperatureMsg.sender = TOS_NODE_ID;
    	SensorTemperatureMsg.receiver = SERIAL_ADDR;
    	SensorTemperatureMsg.sensor = 0;	
    	SensorTemperatureMsg.seqNum = 1;
         	
     	SensorLightMsg.interval = DEFAULT_SAMPLING_INTERVAL;
    	SensorLightMsg.sender = TOS_NODE_ID;
    	SensorLightMsg.receiver = SERIAL_ADDR;
    	SensorLightMsg.sensor = 0;	
      	SensorLightMsg.seqNum = 1;
     	
     	
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
		
			// forward message
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
  		//dbg("TestSerialCSensor","radio send sensor start\n");
  		if(!radioBusy)
  		{
  			SensorMsg* sensorMsg = call RadioPacket.getPayload(&sndSensor, sizeof (SensorMsg));
  			memcpy(sensorMsg,msg,sizeof(SensorMsg));
  			
  			//dbg("TestSerialCSensor","RadioSendSensorMsg\n");
  			
  			if(call RadioSend.send[AM_SENSORMSG](AM_BROADCAST_ADDR,&sndSensor, sizeof(SensorMsg)) == SUCCESS)
			{
				radioBusy = TRUE;
				dbg("TestSerialCSensor","Node %d forwarded sensor data from node: %d sensor: %d\n",TOS_NODE_ID, msg->sender,msg->sensor);
			}
  		}
  		else
  		{
  			dbg("TestSerialCSensor","RadioSendSensorMsg radioBusy\n");
  		}
  	}
  	
  	
  	
} 
