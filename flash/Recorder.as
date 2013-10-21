package
{
	import com.adobe.audio.format.WAVWriter;
	import flash.events.TimerEvent;
	import flash.events.Event;
	import flash.events.ErrorEvent;
	import flash.events.SampleDataEvent;
	import flash.events.IOErrorEvent;
	import flash.events.ProgressEvent;
	import flash.events.SecurityErrorEvent;
	import flash.external.ExternalInterface;
	import flash.media.Microphone;
	import flash.media.Sound;
	import flash.media.SoundChannel;
	import flash.system.Capabilities;
	import flash.utils.ByteArray;
	import flash.utils.getTimer;
	import flash.utils.Timer;
	import flash.system.Security;
	import flash.system.SecurityPanel;
	import flash.events.StatusEvent;
	import flash.utils.getQualifiedClassName;
	import mx.collections.ArrayCollection;
	import ru.inspirit.net.MultipartURLLoader;

	
	public class Recorder
	{
		public function Recorder(logger:Logger):void
		{
			this.logger = logger;
		}
		
		private var logger:Logger;
		public function addExternalInterfaceCallbacks():void {
			ExternalInterface.addCallback("record", this.record);
			ExternalInterface.addCallback("_stop", this.stop);
			ExternalInterface.addCallback("_play", this.play);
			ExternalInterface.addCallback("upload", this.upload);
			ExternalInterface.addCallback("audioData", this.audioData);
			ExternalInterface.addCallback("showFlash", this.showFlash);
			ExternalInterface.addCallback("recordingDuration", this.recordingDuration);
			ExternalInterface.addCallback("playDuration", this.playDuration);

			triggerEvent("initialized", {});
			logger.log("Recorder initialized");
		}

		protected var isRecording:Boolean = false;
		protected var isPlaying:Boolean = false;
		protected var microphoneWasMuted:Boolean;
		protected var playingProgressTimer:Timer;
		protected var microphone:Microphone;
		protected var buffer:ByteArray = new ByteArray();
		protected var sound:Sound;
		protected var channel:SoundChannel;
		protected var recordingStartTime:int = 0;
		protected static var sampleRate:Number = 11.025;
		
		protected function record():void
		{
			if(!microphone) {
				setupMicrophone();
			}

			microphoneWasMuted = microphone.muted;
			if (microphoneWasMuted) {
				logger.log('showFlashRequired');
				triggerEvent('showFlash','');
			}
			else {
				notifyRecordingStarted();
			}

			buffer = new ByteArray();
			microphone.addEventListener(SampleDataEvent.SAMPLE_DATA, recordSampleDataHandler);
		}
		
		protected function recordStop():int
		{
			if (isRecording) {
				logger.log('stopRecording');
				isRecording = false;
				triggerEvent('recordingStop', {duration: recordingDuration()});
				microphone.removeEventListener(SampleDataEvent.SAMPLE_DATA, recordSampleDataHandler);
				return recordingDuration();
			}
			return 0;
		}
		
		protected function play():void
		{
			logger.log('startPlaying');
			isPlaying = true;
			triggerEvent('playingStart', {});
			buffer.position = 0;
			sound = new Sound();
			sound.addEventListener(SampleDataEvent.SAMPLE_DATA, playSampleDataHandler);
			
			channel = sound.play();
			channel.addEventListener(Event.SOUND_COMPLETE, function():void {
				playStop();
			});
			
			if (playingProgressTimer) {
				playingProgressTimer.reset();
			}
			playingProgressTimer = new Timer(250);
			var that:Recorder = this;
			playingProgressTimer.addEventListener(TimerEvent.TIMER, function playingProgressTimerHandler(event:TimerEvent):void {
				triggerEvent('playingProgress', that.playDuration());
			});
			playingProgressTimer.start();
		}
		
		protected function stop():int
		{
			playStop();
			return recordStop();
		}
		
		protected function playStop():void
		{
			logger.log('stopPlaying');
			if (channel) {
				channel.stop();
				playingProgressTimer.reset();
				
				triggerEvent('playingStop', {});
				isPlaying = false;
			}
		}
		
		/* Networking functions */
		
		protected function upload(uri:String, audioParam:String, parameters:*):void
		{
			logger.log("upload");
			buffer.position = 0;
			var wav:ByteArray = prepareWav();
			var ml:MultipartURLLoader = new MultipartURLLoader();
			ml.addEventListener(Event.COMPLETE, onReady);
			function onReady(e:Event):void
			{
				triggerEvent('uploadSuccess', externalInterfaceEncode(e.target.loader.data));
				logger.log('uploading done');
			}
			ml.addEventListener(ProgressEvent.PROGRESS, onProgress);
			function onProgress(e:ProgressEvent):void
			{
				triggerEvent('uploadProgress', e.target.loader.bytesLoaded);
				logger.log('upload progress');
			}
			ml.addEventListener(IOErrorEvent.IO_ERROR, onIOErrorEvent);
			function onIOErrorEvent(e:IOErrorEvent):void
			{
				triggerEvent('uploadIoError', e);
				logger.log('io error occurred during upload');
			}
			ml.addEventListener(SecurityErrorEvent.SECURITY_ERROR, onSecurityErrorEvent);
			function onSecurityErrorEvent(e:SecurityErrorEvent):void
			{
				triggerEvent('uploadSecurityError', e);
				logger.log('security error occurred during upload');
			}

			if (getQualifiedClassName(parameters.constructor) == "Array") {
				for (var i:int = 0; i < parameters.length; i++) {
					ml.addVariable(parameters[i][0], parameters[i][1]);
				}
			}
			else {
				for (var k:* in parameters) {
					ml.addVariable(k, parameters[k]);
				}
			}
			
			ml.addFile(wav, 'audio.wav', audioParam);
			ml.load(uri, false);
		}
		
		private function externalInterfaceEncode(data:String):String {
			return data.split("%").join("%25").split("\\").join("%5c").split("\"").join("%22").split("&").join("%26");
		}
		
		protected function audioData(newData:String = null):String
		{
			var delimiter:String = ";"
			if (newData) {
				buffer = new ByteArray();
				var splittedData:Array = newData.split(delimiter);
				for (var i:int = 0; i < splittedData.length; i++) {
					buffer.writeFloat(parseFloat(splittedData[i]));
				}
				return "";
			}
			else {
				var ret:String = "";
				buffer.position = 0;
				while (buffer.bytesAvailable > 0) {
					ret += buffer.readFloat().toString() + delimiter;
				}
				return ret;
			}
		}
		
		protected function showFlash():void
		{
			Security.showSettings(SecurityPanel.PRIVACY);
			triggerEvent('showFlash','');
		}
		
		/* Recording Helper */
		protected function setupMicrophone():void
		{
			logger.log('setupMicrophone');
			microphone = Microphone.getMicrophone();
			microphone.codec = "Nellymoser";
			microphone.setSilenceLevel(0);
			microphone.rate = sampleRate;
			microphone.gain = 70;
			microphone.addEventListener(StatusEvent.STATUS, function statusHandler(e:Event):void {
				logger.log('Microphone Status Change');
				if (microphone.muted) {
					triggerEvent('recordingCancel','');
				}
				else {
					if (!isRecording) {
						notifyRecordingStarted();
					}
				}
			});

			logger.log('setupMicrophone done: ' + microphone.name + ' ' + microphone.muted);
		}
		
		protected function notifyRecordingStarted():void
		{
			if (microphoneWasMuted) {
				microphoneWasMuted = false;
				triggerEvent('hideFlash','');
			}
			recordingStartTime = getTimer();
			triggerEvent('recordingStart', {});
			logger.log('startRecording');
			isRecording = true;
		}
		
		/* Sample related */
		
		protected function prepareWav():ByteArray
		{
			var wavData:ByteArray = new ByteArray();
			var wavWriter:WAVWriter = new WAVWriter();
			buffer.position = 0;
			wavWriter.numOfChannels = 1; // set the inital properties of the Wave Writer
			wavWriter.sampleBitRate = 8;
			wavWriter.samplingRate = sampleRate * 1000;
			wavWriter.processSamples(wavData, buffer, sampleRate * 1000, 1);
			return wavData;
		}
		
		protected function recordingDuration():int
		{
			var duration:int = int(getTimer() - recordingStartTime);
			return Math.max(duration, 0);
		}

		protected function playDuration():int
		{
			return int(channel.position);
		}
		
		protected function recordSampleDataHandler(event:SampleDataEvent):void
		{
			while (event.data.bytesAvailable) {
				var sample:Number = event.data.readFloat();
				buffer.writeFloat(sample);
			}
      triggerEvent('recordingProgress', recordingDuration(), microphone.activityLevel);
		}
		
		protected function playSampleDataHandler(event:SampleDataEvent):void
		{
			var expectedSampleRate:Number = 44.1;
			var writtenSamples:int = 0;
			var channels:int = 2;
			var maxSamples:int = 8192 * channels;
			// if the sampleRate doesn't match the expectedSampleRate of flash.media.Sound (44.1) write the sample multiple times
			// this will result in a little down pitchshift.
			// also write 2 times for stereo channels
			while (writtenSamples < maxSamples && buffer.bytesAvailable) {
				var sample:Number = buffer.readFloat();
				for (var j:int = 0; j < channels * (expectedSampleRate / sampleRate); j++) {
					event.data.writeFloat(sample);
					writtenSamples++;
					if (writtenSamples >= maxSamples) {
						break;
					}
				}
			}
			logger.log("Wrote " + writtenSamples + " samples");
		}
		
		/* ExternalInterface Communication */
		
		protected function triggerEvent(eventName:String, arg0:*, arg1:* = null):void
		{
			ExternalInterface.call("Recorder.triggerEvent", eventName, arg0, arg1);
		}
	}
}