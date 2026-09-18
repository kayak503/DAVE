using LocalVoice;
using NAudio.Wave;
using System.Reflection;

internal static class AudioChecks
{
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
 }
 sealed class Tone:ISampleProvider
 {
  public int Position;
  public WaveFormat WaveFormat=>WaveFormat.CreateIeeeFloatWaveFormat(16000,1);
  public int Read(float[] buffer,int offset,int count){for(int i=0;i<count;i++)buffer[offset+i]=(float)Math.Sin((Position++)*.071);return count;}
 }
}
