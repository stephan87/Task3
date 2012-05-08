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
	    interface Leds;
  	}
}
implementation
{
	uint16_t localSeqNumber = 0; ///< stores the msg sequence number
	bool radioBusy	=FALSE;
	bool serialBusy	=FALSE;
	message_t sndSerial; ///< strores the current sent message over serial
	message_t rcvSerial; ///< strores the current received message over serial
	message_t sndRadio; ///< strores the current sent message over radio
	message_t rcvRadio; ///< strores the current received message over radio
	am_addr_t addr;
	MoteTableEntry neighborTable[AM_TABLESIZE];
	
	
	// methods which capsulate the sending of messages
	void serialSendTask(TestSerialMsg* msgToSend);
  	void radioSendTask(TestSerialMsg* msgToSend);
  
  	event void Boot.booted() {
    	call RadioControl.start();
    	if(TOS_NODE_ID == 0){
    		call SerialControl.start();
    	}
    	call BeaconTimer.startPeriodic( AM_BEACONINTERVAL );
  	}
  	
  	/*
  	*	gets fired when a new beacon broadcast needs to be send
  	*/
  	event void BeaconTimer.fired()
  	{
  		dbg("TestSerialC","should send beacon\n");
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
  		if(id == AM_BEACONMSG)
  		{
  			BeaconMsg *msgReceived;
  			uint16_t freeSlot = -1;
  			uint16_t i;
  			
  			msgReceived = (BeaconMsg*)payload;
  			
  			// when received a beacon add an entry to the neighbour table and ack
  			for(i=0;i<AM_TABLESIZE;i++)
  			{
  				MoteTableEntry *curEntry = &neighborTable[i];
  				if((curEntry == NULL) && (freeSlot != -1))
  				{
  					freeSlot = i;
  				}
  				else
  				{
  					if(curEntry->nodeId == msgReceived->sender)
  					{
  						curEntry->lastContact = time(NULL); // returns seconds
  						dbg("TestSerialC","found entry in neighbor table - update time\n");
  					}
  				}
  			}
  			if(freeSlot == -1)
  				dbg("TestSerialC","found NO entry in neighbor table\n");
  			return msg;
  		}
  		// got the right message to cast ?	
  		if (len == sizeof(TestSerialMsg))
  		{
    		TestSerialMsg *msgReceived;
  			memcpy(&rcvRadio,payload,len);
    		msgReceived = (TestSerialMsg*)&rcvRadio;
    		
			if(msgReceived->receiver == TOS_NODE_ID)
			{
    			if(msgReceived->seqNum > localSeqNumber)
    			{
    				dbg("TestSerialC","Finished Node %d: received message on RadioChannel seqNum: %d\n",TOS_NODE_ID,msgReceived->seqNum);
    				localSeqNumber = msgReceived->seqNum;
    				call Leds.set(msgReceived->ledNum);
    			}
    			else
    			{
	    			dbg("TestSerialC","Node %d:duplicate message received\n",TOS_NODE_ID);
	    		}
	    	}
	    	else
	    	{
    			radioSendTask(msgReceived);
    		}
		}
    	return msg;
  	}
  
	/*
	*	Sends the received message from pc directly back to the pc (used as a message received indication)
	*/
  	void serialSendTask(TestSerialMsg *receivedMsgToSend) 
  	{	
		// is radio unused?
		if(!serialBusy){ 			
			TestSerialMsg* msgToSend = (TestSerialMsg*)(call SerialPacket.getPayload(&sndSerial, sizeof (TestSerialMsg)));
			msgToSend->sender = receivedMsgToSend->sender;
			msgToSend->seqNum = receivedMsgToSend->seqNum;
			msgToSend->ledNum = receivedMsgToSend->ledNum;
			msgToSend->receiver = receivedMsgToSend->receiver;
		
			// forward message
			if(call SerialSend.send[AM_TESTSERIALMSG](AM_BROADCAST_ADDR,&sndSerial, sizeof(TestSerialMsg)) == SUCCESS){
				serialBusy = TRUE;
			}
		}
  	}

  	event void SerialSend.sendDone[am_id_t id](message_t* msg, error_t error)
  	{
	    if (error == SUCCESS)
	    {
		// has the sent message the right pointer
	      	if(&sndSerial == msg)
	      	{
	      		dbg("TestSerialC", "successfully sent message over serial\n");
	      		serialBusy = FALSE;
	      		call Leds.led1Toggle();
	      		return;
	      	}
	    }
  		dbg("TestSerialC", "error on message pointer\n");
  	}

  	event message_t *SerialReceive.receive[am_id_t id](message_t *msg, void *payload, uint8_t len)
  	{  		
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
    				serialSendTask((TestSerialMsg*)msgReceived);
    			}
    			else
    			{
	    			// is radio unused?
	    			if(!radioBusy)
	    			{   			
						TestSerialMsg* msgToSend = (TestSerialMsg*)(call RadioPacket.getPayload(&sndRadio, sizeof (TestSerialMsg)));
						msgToSend->sender = msgReceived->sender;
						msgToSend->seqNum = msgReceived->seqNum;
						msgToSend->ledNum = msgReceived->ledNum;
						msgToSend->receiver = msgReceived->receiver;
						
						// forward message
						if(call RadioSend.send[AM_TESTSERIALMSG](AM_BROADCAST_ADDR,&sndRadio, sizeof(TestSerialMsg)) == SUCCESS)
						{
							//dbg("BlinkToRadio", "message sent - busy set to true @ %s.\n", sim_time_string());
							radioBusy = TRUE;
							serialSendTask((TestSerialMsg*)msgReceived);
						}
					}
				}
    		}
  		}	  		
  		return msg;
  	}

  	void radioSendTask(TestSerialMsg *receivedMsgToSend)
  	{
		// is radio unused?
		if(!radioBusy)
		{		
			TestSerialMsg* msgToSend = (TestSerialMsg*)(call RadioPacket.getPayload(&sndRadio, sizeof (TestSerialMsg)));
			msgToSend->sender = receivedMsgToSend->sender;
			msgToSend->seqNum = receivedMsgToSend->seqNum;
			msgToSend->ledNum = receivedMsgToSend->ledNum;
			msgToSend->receiver = receivedMsgToSend->receiver;
			
			// forward message broadcast
			if(call RadioSend.send[AM_TESTSERIALMSG](AM_BROADCAST_ADDR,&sndRadio, sizeof(TestSerialMsg)) == SUCCESS)
			{
				radioBusy = TRUE;
				dbg("TestSerialC","Node %d forwarded message\n",TOS_NODE_ID);
			}
		}
  	}
  	
  	void beaconSendTask(BeaconMsg *beaconMsg)
  	{
		// is radio unused?
		if(!radioBusy)
		{	
			message_t beacon;	
			BeaconMsg* msgToSend = (BeaconMsg*)(call RadioPacket.getPayload(&beacon, sizeof (BeaconMsg)));
			msgToSend->sender = TOS_NODE_ID;
			
			// forward message broadcast
			if(call RadioSend.send[AM_BEACONMSG](AM_BROADCAST_ADDR,&beacon, sizeof(BeaconMsg)) == SUCCESS)
			{
				radioBusy = TRUE;
				dbg("TestSerialC","Node %d sent beacon message\n",TOS_NODE_ID);
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
    		if(TOS_NODE_ID == 0)
    		{
    			call Leds.led0Toggle();
    		}
 			radioBusy = FALSE;
		}
  	}
} 
