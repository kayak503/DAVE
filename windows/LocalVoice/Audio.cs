using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using NAudio.CoreAudioApi;
namespace LocalVoice;
public sealed class Recorder:IDisposable {
 WaveInEvent? input; readonly List<float> samples=new();
 public event Action<float>? Level;public bool Active=>input!=null;
 public void Start(){if(Active)return;samples.Clear();var source=new WaveInEvent{WaveFormat=new WaveFormat(16000,16,1),BufferMilliseconds=50};source.DataAvailable+=(_,e)=>{double sum=0;lock(samples){for(int i=0;i<e.BytesRecorded;i+=2){float value=BitConverter.ToInt16(e.Buffer,i)/32768f;samples.Add(value);sum+=value*value;}}Level?.Invoke((float)Math.Sqrt(sum/Math.Max(1,e.BytesRecorded/2)));};input=source;try{source.StartRecording();}catch{input=null;source.Dispose();throw;}}
 public async Task<float[]> Stop(){var source=input;if(source==null)return Array.Empty<float>();input=null;var done=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);source.RecordingStopped+=(_,e)=>{if(e.Exception!=null)done.TrySetException(e.Exception);else done.TrySetResult();};source.StopRecording();try{await done.Task.WaitAsync(TimeSpan.FromSeconds(5));lock(samples)return samples.ToArray();}finally{source.Dispose();}}
 public void Dispose(){input?.StopRecording();input?.Dispose();input=null;}
}
public sealed class AudioPlayer:IDisposable {
 IWavePlayer? output;AudioFileReader? file;RateProvider? speed;TaskCompletionSource? completion;
 public bool Finished=>completion?.Task.IsCompleted??false;
 public double Position=>file?.CurrentTime.TotalSeconds??0;
 public bool Playing=>output?.PlaybackState==PlaybackState.Playing;
 public double Duration=>file?.TotalTime.TotalSeconds??0;
 public double Rate{get=>speed?.Rate??1;set{if(speed!=null)speed.Rate=value;}}
 public Task Play(string path,double rate=1,double position=0){Stop();try{file=new AudioFileReader(path);file.CurrentTime=TimeSpan.FromSeconds(Math.Clamp(position,0,file.TotalTime.TotalSeconds));speed=new RateProvider(file,rate);output=new WasapiOut(AudioClientShareMode.Shared,true,100);completion=new(TaskCreationOptions.RunContinuationsAsynchronously);var done=completion;output.PlaybackStopped+=(_,e)=>{if(e.Exception!=null)done.TrySetException(e.Exception);else done.TrySetResult();};output.Init(speed);output.Play();return done.Task;}catch{Stop();throw;}}
 public void Seek(double seconds){if(file!=null&&speed!=null)speed.Seek(()=>file.CurrentTime=TimeSpan.FromSeconds(Math.Clamp(seconds,0,file.TotalTime.TotalSeconds)));}
 public void Pause(){if(output?.PlaybackState==PlaybackState.Playing)output.Pause();else if(output?.PlaybackState==PlaybackState.Paused)output.Play();}
 public void Stop(){output?.Stop();output?.Dispose();output=null;file?.Dispose();file=null;speed=null;completion?.TrySetCanceled();completion=null;}
 public void Dispose()=>Stop();
 // SoundTouch changes tempo alone: no resampling/pitch-correction cascade.
 // All processor access is serialized with the audio callback, including seek/rate changes.
 sealed class RateProvider:ISampleProvider {
  readonly ISampleProvider source;
  SoundTouch.SoundTouchProcessor processor;
  readonly float[] input;
  readonly object gate=new();
  bool ended,direct;double rate;
  public WaveFormat WaveFormat=>source.WaveFormat;
  public double Rate {get{lock(gate)return rate;}set{lock(gate){rate=Math.Clamp(value,.5,2);processor.Tempo=rate;if(rate!=1)direct=false;}}}
  public RateProvider(ISampleProvider source,double rate){
   this.source=source;processor=new(){SampleRate=source.WaveFormat.SampleRate,Channels=source.WaveFormat.Channels};
   input=new float[4096*source.WaveFormat.Channels];direct=rate==1;Rate=rate;
  }
  public void Seek(Action seek){lock(gate){seek();processor=new(){SampleRate=WaveFormat.SampleRate,Channels=WaveFormat.Channels,Tempo=rate};ended=false;direct=rate==1;}}
  public int Read(float[] buffer,int offset,int requested){lock(gate){
   int channels=WaveFormat.Channels;requested-=requested%channels;
   if(direct)return source.Read(buffer,offset,requested);
   int written=0;
   while(written<requested){
    int frames=processor.ReceiveSamples(buffer.AsSpan(offset+written,requested-written),(requested-written)/channels);
    written+=frames*channels;
    if(written==requested||ended&&frames==0)break;
    if(frames>0)continue;
    int count=source.Read(input,0,input.Length);
    if(count>0)processor.PutSamples(input.AsSpan(0,count),count/channels);
    else{processor.Flush();ended=true;}
   }
   return written;
  }}
 }
}
public sealed class ChunkReader:IDisposable {
 readonly AudioFileReader reader;readonly ISampleProvider samples;public double Duration=>reader.TotalTime.TotalSeconds;
 public ChunkReader(string path){reader=new AudioFileReader(path);ISampleProvider source=reader;if(source.WaveFormat.Channels==2)source=new StereoToMonoSampleProvider(source);else if(source.WaveFormat.Channels!=1)throw new InvalidDataException("Use a mono or stereo audio file.");samples=new WdlResamplingSampleProvider(source,16000);}
 public float[] Next(){var data=new float[30*16000];int count=0,n;while(count<data.Length&&(n=samples.Read(data,count,data.Length-count))>0)count+=n;return data[..count];}
 public void Dispose()=>reader.Dispose();
}
