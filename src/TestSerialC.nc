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
	    interface Leds;
  	}
}
implementation
{
	uint16_t localSeqNumber = 0; ///< stores the msg sequence number
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
	uint16_t testCounter = 0;
	MoteTableEntry neighborTable[AM_TABLESIZE];
	message_t radioSendQueue[AM_SENDRADIOQ_LEN];
	
	
	
	// methods which capsulate the sending of messages
	task void serialSendTask();
  	void radioSend(TestSerialMsg* msgToSend);
  	void beaconSend();
  	void initNeighborTable();
  	task void sendRadioAck();
  
  	event void Boot.booted() {
	
    	call RadioControl.start();
    	if(TOS_NODE_ID == 0){
    		call SerialControl.start();
    	}
    	initNeighborTable();
    	call BeaconTimer.startPeriodic( AM_BEACONINTERVAL );
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
  			radioSend((TestSerialMsg*)&rcvRadio);
  			// TODO retransmit des letzen commandos...
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
  						curEntry->lastContact = time(NULL); // returns seconds
  						//dbg("TestSerialC","curEntry->nodeID: %d found entry for node: %d in neighbor table - update time\n",curEntry->nodeId,msgReceived->sender);
  					}
  					// otherwise delete the node in the table when the timelimit AM_BEACONTIMEOUT is reached
  					else
  					{
  						uint16_t timediff = (time(NULL) - curEntry->lastContact);
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
  					neighborTable[freeSlot].lastContact = time(NULL);
  				}
  			}
  			return msg;
  		}
  		// got the right message to cast ?
  		 		
  		if (len == sizeof(TestSerialMsg))
  		{
    		TestSerialMsg *msgReceived;
  			memcpy(&rcvRadio,payload,len);
    		msgReceived = (TestSerialMsg*)&rcvRadio;
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
    				dbg("TestSerialC","Finished Node %d: received message on RadioChannel seqNum: %d\n",TOS_NODE_ID,msgReceived->seqNum);
    				localSeqNumber = msgReceived->seqNum;
    				call Leds.set(msgReceived->ledNum);
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
    	return msg;
  	}
  
  	task void sendRadioAck()
  	{
  		//dbg("TestSerialC","Send Ack to node: %d\n",lastMsg->sender);
  		// is radio unused?
		if(!radioBusy)
		{
			TestSerialMsg* lastMsg = (TestSerialMsg*)&rcvRadio;
			//TestSerialMsg* sent = (TestSerialMsg*)&sndRadio;
			TestSerialMsg* msgToSend = (TestSerialMsg*)(call RadioPacket.getPayload(&sndRadio, sizeof (TestSerialMsg)));
			//dbg("TestSerialC","override sndRadio\n");
			//dbg("TestSerialC","send radio ack -> sndRadio-recv: %d sndRadio-sender: %d sndRadio-ack: %d\n",sent->receiver,sent->sender, sent->isAck);
			
			msgToSend->sender = TOS_NODE_ID;
			msgToSend->seqNum = lastMsg->seqNum;
			msgToSend->ledNum = lastMsg->ledNum;
			msgToSend->receiver = lastMsg->sender;
			msgToSend->isAck = 1;
			
			memcpy(&sndRadioLast,msgToSend,sizeof(TestSerialMsg));
			
			dbg("TestSerialC","send ack to: %d from %d\n",lastMsg->sender,TOS_NODE_ID);
			
			// forward message broadcast
			if(call RadioSend.send[AM_TESTSERIALMSG](lastMsg->sender,&sndRadio, sizeof(TestSerialMsg)) == SUCCESS)
			{
				radioBusy = TRUE;
			}
		}
  	}
  	
	/*
	*	Sends the received message from pc directly back to the pc (used as a message received indication)
	*/
  	task void serialSendTask() 
  	{	
		// is radio unused?
		if(!serialBusy){
			TestSerialMsg* msgReceived = (TestSerialMsg*)&rcvSerial;			
			TestSerialMsg* msgToSend = (TestSerialMsg*)(call SerialPacket.getPayload(&sndSerial, sizeof (TestSerialMsg)));
			msgToSend->sender = TOS_NODE_ID;
			msgToSend->seqNum = msgReceived->seqNum;
			msgToSend->ledNum = msgReceived->ledNum;
			msgToSend->receiver = msgReceived->sender;
			msgToSend->isAck = TRUE;
		
			// forward message
			if(call SerialSend.send[AM_TESTSERIALMSG](msgReceived->sender,&sndSerial, sizeof(TestSerialMsg)) == SUCCESS){
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
	      	if(&sndSerial == msg)
	      	{
	      		dbg("TestSerialC", "send done: serial\n");
	      		serialBusy = FALSE;
	      		call Leds.led1Toggle();
	      		return;
	      	}
	    }
  		dbg("TestSerialC", "error on message pointer\n");
  	}

  	event message_t *SerialReceive.receive[am_id_t id](message_t *msg, void *payload, uint8_t len)
  	{  	
  		dbg("TestSerialC","received message on serial channel\n");	
  		// got the right message to cast ?
  		if (len == sizeof(TestSerialMsg))
  		{
    		TestSerialMsg *msgReceived;
  			memcpy(&rcvSerial,payload,len);
    		msgReceived = (TestSerialMsg*)&rcvSerial;
    		    		
    		// check sequence number to avoid sending of duplicates
    		if(msgReceived->seqNum > localSeqNumber)
    		{
    			localSeqNumber=msgReceived->seqNum;
    			
    			if(msgReceived->receiver == TOS_NODE_ID)
    			{
    				call Leds.set(msgReceived->ledNum);
    				post serialSendTask();
    			}
    			else
    			{
	    			// is radio unused?
	    			if(!radioBusy)
	    			{   			
						TestSerialMsg* msgToSend = (TestSerialMsg*)(call RadioPacket.getPayload(&sndRadio, sizeof (TestSerialMsg)));
						msgToSend->sender = TOS_NODE_ID;
						msgToSend->seqNum = msgReceived->seqNum;
						msgToSend->ledNum = msgReceived->ledNum;
						msgToSend->receiver = msgReceived->receiver;
						msgToSend->isAck = 0;
						
						memcpy(&sndRadioLast,msgToSend,sizeof(TestSerialMsg));
						
						// forward message
						if(call RadioSend.send[AM_TESTSERIALMSG](AM_BROADCAST_ADDR,&sndRadio, sizeof(TestSerialMsg)) == SUCCESS)
						{
							dbg("TestSerialC", "message sent - msgToSend->isAck: %d, receiver: %d\n", msgToSend->isAck, msgToSend->receiver);
							radioBusy = TRUE;
							post serialSendTask();
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

  	void radioSend(TestSerialMsg *receivedMsgToSend)
  	{
		// is radio unused?
		if(!radioBusy)
		{		
			TestSerialMsg* msgToSend = (TestSerialMsg*)(call RadioPacket.getPayload(&sndRadio, sizeof (TestSerialMsg)));
			msgToSend->sender = TOS_NODE_ID;
			msgToSend->seqNum = receivedMsgToSend->seqNum;
			msgToSend->ledNum = receivedMsgToSend->ledNum;
			msgToSend->receiver = receivedMsgToSend->receiver;
			msgToSend->isAck = 0;
			
			memcpy(&sndRadioLast,msgToSend,sizeof(TestSerialMsg));
			
			// forward message broadcast
			if(call RadioSend.send[AM_TESTSERIALMSG](AM_BROADCAST_ADDR,&sndRadio, sizeof(TestSerialMsg)) == SUCCESS)
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

  	event void RadioSend.sendDone[am_id_t id](message_t* msg, error_t error)
  	{
    	if (error != SUCCESS)
    	{
    		dbg("TestSerialC","Error: Node %d couldnt send message on RadioChannel\n",TOS_NODE_ID);
    	}
    	else
    	{
    		//dbg("TestSerialC","send done for ch id: %d\n",id);
    		if(id == AM_TESTSERIALMSG)
    		{
    			TestSerialMsg* sentMsg;
	    		if(TOS_NODE_ID == 0)
	    		{
	    			call Leds.led0Toggle();
	    		}
 			
	 			// start a timer within all neighbors in the table must acknowledge the receival
	 			sentMsg = (TestSerialMsg*)&sndRadioLast;
	 			dbg("TestSerialC","sentMsg->isAck: %d, receiver: %d, sender: %d\n",sentMsg->isAck,sentMsg->receiver,sentMsg->sender);
	 			if(!sentMsg->isAck)
	 			{
	 				dbg("TestSerialC","send done for normal message-> start timer\n");
	 				call AckTimer.startOneShot( AM_ACKTIMEOUT );
	 			}
	 		}
		}
		radioBusy = FALSE;
  	}
} 
