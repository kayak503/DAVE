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
 // Change rate without regenerating speech. Pitch correction compensates the resampling ratio.
 sealed class RateProvider:ISampleProvider {
  readonly ISampleProvider source;SmbPitchShiftingSampleProvider pitch;readonly float[] input;int count;double cursor;double rate;
  public double Rate{get=>rate;set{rate=Math.Clamp(value,.5,2);pitch.PitchFactor=(float)(1/rate);}}
  public WaveFormat WaveFormat=>source.WaveFormat;
  public RateProvider(ISampleProvider source,double rate){this.source=source;pitch=new SmbPitchShiftingSampleProvider(source);input=new float[16384*source.WaveFormat.Channels];Rate=rate;}
  bool ended;
  public void Seek(Action seek){lock(this){seek();count=0;cursor=0;ended=false;pitch=new SmbPitchShiftingSampleProvider(source){PitchFactor=(float)(1/rate)};}}
  public int Read(float[] buffer,int offset,int requested){lock(this)return ReadCore(buffer,offset,requested);}
  int ReadCore(float[] buffer,int offset,int requested){
   int channels=WaveFormat.Channels,written=0;
   while(written+channels<=requested){
    int frame=(int)cursor;
    while(!ended&&(frame+1)*channels>=count){
     int consumed=Math.Min(frame*channels,count);
     if(consumed>0){Array.Copy(input,consumed,input,0,count-consumed);count-=consumed;cursor-=consumed/channels;frame=(int)cursor;}
     int n=pitch.Read(input,count,input.Length-count);if(n==0)ended=true;else count+=n;
    }
    if(frame*channels>=count)return written;
    int next=Math.Min(frame+1,count/channels-1);double fraction=cursor-frame;
    for(int c=0;c<channels;c++){float a=input[frame*channels+c],b=input[next*channels+c];buffer[offset+written++]=(float)(a+(b-a)*fraction);}
    cursor+=rate;
   }
   return written;
  }
 }
}
public sealed class ChunkReader:IDisposable {
 readonly AudioFileReader reader;readonly ISampleProvider samples;public double Duration=>reader.TotalTime.TotalSeconds;
 public ChunkReader(string path){reader=new AudioFileReader(path);ISampleProvider source=reader;if(source.WaveFormat.Channels==2)source=new StereoToMonoSampleProvider(source);else if(source.WaveFormat.Channels!=1)throw new InvalidDataException("Use a mono or stereo audio file.");samples=new WdlResamplingSampleProvider(source,16000);}
 public float[] Next(){var data=new float[30*16000];int count=0,n;while(count<data.Length&&(n=samples.Read(data,count,data.Length-count))>0)count+=n;return data[..count];}
 public void Dispose()=>reader.Dispose();
}
