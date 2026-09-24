using LocalVoice;
using NAudio.Wave;
using System.Reflection;

internal static class AudioChecks
{
 internal static void WriteSpeechSamples(string output)
 {
  System.IO.Directory.CreateDirectory(output);string original=System.IO.Path.Combine(output,"speech-1x.wav");
  using(var voice=new System.Speech.Synthesis.SpeechSynthesizer()){voice.SetOutputToWaveFile(original);voice.Rate=0;voice.Speak("This is Dave. Your words stay on your computer. You can listen faster while the voice keeps its natural pitch. Pause, resume, or jump to the next sentence whenever you like.");}
  var type=typeof(AudioPlayer).GetNestedType("RateProvider",BindingFlags.NonPublic)!;
  foreach(double rate in new[]{1.2,1.5,2}){using var source=new AudioFileReader(original);var processor=(ISampleProvider)Activator.CreateInstance(type,source,rate)!;WaveFileWriter.CreateWaveFile16(System.IO.Path.Combine(output,$"speech-{rate:0.#}x.wav"),processor);}
 }
 // Check buffered seek without playing sound or requiring an audio device.
 internal static void Run()
 {
  var type=typeof(AudioPlayer).GetNestedType("RateProvider",BindingFlags.NonPublic)!;
  var source=new Tone();
  var instance=Activator.CreateInstance(type,source,1.5)!;
  var provider=(ISampleProvider)instance;
  var before=new float[4000];provider.Read(before,0,before.Length);
  type.GetMethod("Seek")!.Invoke(instance,new object[]{(Action)(()=>source.Position=16000)});
  var expectedSource=new Tone{Position=16000};
  var expected=(ISampleProvider)Activator.CreateInstance(type,expectedSource,1.5)!;
  var actual=new float[4000];var reference=new float[4000];
  int count=provider.Read(actual,0,actual.Length),expectedCount=expected.Read(reference,0,reference.Length);
  if(count!=expectedCount||!actual.SequenceEqual(reference))throw new Exception("Seek retained samples or pitch state from the old position.");
  foreach(int sampleRate in new[]{16000,24000,48000})foreach(int channels in new[]{1,2})foreach(double rate in new[]{.5,1,1.2,1.5,2})
  {
   var tone=new FiniteTone(sampleRate,channels);
   var processed=(ISampleProvider)Activator.CreateInstance(type,tone,rate)!;
   var output=Drain(processed);int frames=output.Length/channels;
   if(Math.Abs(frames-sampleRate*2/rate)>sampleRate*.025)throw new Exception($"Incorrect tempo duration: {sampleRate}/{channels} at {rate}×: {frames} frames.");
   for(int channel=0;channel<channels;channel++){
    int start=frames/4,end=frames*3/4,crossings=0;
    for(int frame=start+1;frame<end;frame++)if(output[(frame-1)*channels+channel]<=0&&output[frame*channels+channel]>0)crossings++;
    double frequency=crossings*sampleRate/(double)(end-start),expectedHz=channel==0?220:330;
    if(Math.Abs(frequency-expectedHz)>5)throw new Exception($"Pitch shifted at {rate}×: {frequency} Hz instead of {expectedHz} Hz.");
   }
   if(output.Any(value=>!float.IsFinite(value)||Math.Abs(value)>1))throw new Exception("Tempo processing produced invalid/clipped audio.");
   if(rate==1){var normal=Drain(new FiniteTone(sampleRate,channels));if(!normal.SequenceEqual(output))throw new Exception("1× playback must preserve samples exactly.");}
  }
  // Rate changes on a running stream must drain, terminate and keep sample values valid.
  var dynamicSource=new FiniteTone(24000,2);var dynamic=Activator.CreateInstance(type,dynamicSource,1d)!;var providerDynamic=(ISampleProvider)dynamic;
  var chunk=new float[512];providerDynamic.Read(chunk,0,chunk.Length);type.GetProperty("Rate")!.SetValue(dynamic,2d);providerDynamic.Read(chunk,0,chunk.Length);type.GetProperty("Rate")!.SetValue(dynamic,1d);Drain(providerDynamic);
 }
 static float[] Drain(ISampleProvider provider){var output=new List<float>();var block=new float[1024];for(int iteration=0;iteration<10000;iteration++){int n=provider.Read(block,0,block.Length);if(n==0)return output.ToArray();output.AddRange(block.Take(n));}throw new Exception("Audio stream did not terminate.");}
 sealed class FiniteTone:ISampleProvider {
  readonly int sampleRate,channels;int position;
  public WaveFormat WaveFormat=>WaveFormat.CreateIeeeFloatWaveFormat(sampleRate,channels);
  public FiniteTone(int sampleRate,int channels){this.sampleRate=sampleRate;this.channels=channels;}
  public int Read(float[] buffer,int offset,int count){int n=Math.Min(count,sampleRate*2*channels-position);for(int i=0;i<n;i++){int frame=position/channels,channel=position%channels;buffer[offset+i]=.4f*(float)Math.Sin(frame*2*Math.PI*(channel==0?220:330)/sampleRate);position++;}return n;}
 }
 sealed class Tone:ISampleProvider
 {
  public int Position;
  public WaveFormat WaveFormat=>WaveFormat.CreateIeeeFloatWaveFormat(16000,1);
  public int Read(float[] buffer,int offset,int count){for(int i=0;i<count;i++)buffer[offset+i]=(float)Math.Sin((Position++)*.071);return count;}
 }
}
