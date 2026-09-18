using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
namespace LocalVoice;

public sealed class Preferences {
 public string DictationModel {get;set;}="whisper-tiny";
 public string TranscriptionModel {get;set;}="whisper-small";
 public string ReadingModel {get;set;}="system";
 public string ReadingVoice {get;set;}="";
 public Dictionary<string,string> Voices {get;set;}=new();
 public string DictationDevice {get;set;}="auto";
 public string TranscriptionDevice {get;set;}="auto";
 public string SpeakerModel {get;set;}="compact";
 public bool SeparateSpeakers {get;set;}=true;
 public int ExpectedSpeakers {get;set;}=0;
 public int ReadAhead {get;set;}=5;
 public bool ReadCode {get;set;}=false;
 public bool OverlayAtTop {get;set;}=false;
 public double Rate {get;set;}=1;
 public uint ReadModifiers {get;set;}=3; // Control + Alt
 public uint ReadKey {get;set;}=0x52;
 public uint DictateModifiers {get;set;}=3;
 public uint DictateKey {get;set;}=0x44;
 public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Local Voice");
 public static Preferences Load(string? path=null) {
  path ??= Path.Combine(DirectoryPath,"preferences.json");
  if(!File.Exists(path))return new();
  var p=JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path))??throw new InvalidDataException("Preferences are empty.");
  if(!new[]{"auto","cpu","gpu"}.Contains(p.DictationDevice)||!new[]{"auto","cpu","gpu"}.Contains(p.TranscriptionDevice))throw new InvalidDataException("Unknown recognition device in preferences.");
  p.ReadAhead=Math.Clamp(p.ReadAhead,3,10);p.Rate=Math.Clamp(p.Rate,.5,2);p.ExpectedSpeakers=Math.Clamp(p.ExpectedSpeakers,0,20);return p;
 }
 public void Save(string? path=null) {
  path ??= Path.Combine(DirectoryPath,"preferences.json");Directory.CreateDirectory(Path.GetDirectoryName(path)!);
  var stage=path+"."+Guid.NewGuid()+".tmp";
  try{File.WriteAllText(stage,JsonSerializer.Serialize(this,new JsonSerializerOptions{WriteIndented=true}));File.Move(stage,path,true);}finally{if(File.Exists(stage))File.Delete(stage);}
 }
}
public sealed class Model {
 [JsonPropertyName("id")]public string Id{get;set;}="";
 [JsonPropertyName("name")]public string Name{get;set;}="";
 [JsonPropertyName("task")]public string Task{get;set;}="";
 [JsonPropertyName("variantOf")]public string? VariantOf{get;set;}
 [JsonPropertyName("installed")]public bool Installed{get;set;}
 [JsonPropertyName("sizeMB")]public double SizeMB{get;set;}
 [JsonPropertyName("description")]public string? Description{get;set;}
 [JsonPropertyName("voices")]public Voice[]? Voices{get;set;}
 public override string ToString()=>Name+(Installed?" · ready":" · download needed");
}
public sealed class Voice {
 [JsonPropertyName("id")]public string Id{get;set;}="";
 [JsonPropertyName("name")]public string Name{get;set;}="";
 public override string ToString()=>Name;
}
public sealed class SpeakerModel {
 [JsonPropertyName("id")]public string Id{get;set;}="";
 [JsonPropertyName("name")]public string Name{get;set;}="";
 [JsonPropertyName("installed")]public bool Installed{get;set;}
 [JsonPropertyName("sizeMB")]public double SizeMB{get;set;}
 public override string ToString()=>Name+(Installed?" · ready":" · download needed");
}
public sealed class Caption {
 public Guid Id{get;set;}=Guid.NewGuid();
 [JsonPropertyName("start")]public double Start{get;set;}
 [JsonPropertyName("end")]public double End{get;set;}
 [JsonPropertyName("text")]public string Text{get;set;}="";
 [JsonPropertyName("speaker")]public string? Speaker{get;set;}
 [JsonPropertyName("speakerEmbedding")]public double[]? Embedding{get;set;}
 public bool Confirmed{get;set;}
 public string? DetectedSpeaker{get;set;}
 public bool Reclassified{get;set;}
 public Caption Clone()=>(Caption)MemberwiseClone();
}
public sealed class Transcript {
 public string SpeakerModel{get;set;}="compact";
 public List<Caption> Captions{get;set;}=new();
 public Dictionary<string,string> Names{get;set;}=new();
 readonly Stack<(List<Caption>,Dictionary<string,string>)> undo=new();
 public bool CanUndo=>undo.Count>0;
 public string Name(string? id)=>id==null?"":Names.GetValueOrDefault(id)??string.Join(" + ",id.Split(" + ").Select(x=>Names.GetValueOrDefault(x,x)));
 public string[] Speakers=>Captions.Select(x=>x.Speaker).Where(x=>x!=null&&!x.Contains(" + ")).Cast<string>().Union(Names.Keys).Order().ToArray();
 void Snapshot()=>undo.Push((Captions.Select(x=>x.Clone()).ToList(),new(Names)));
 public void NameFirst(Guid caption,string name) {
  var c=Captions.First(x=>x.Id==caption);name=CleanName(name);
  if(c.Speaker==null||c.Speaker.Contains(" + ")||name.Length==0)throw new ArgumentException("Select one speaker and enter a name.");
  Snapshot();Names[c.Speaker]=name;c.Confirmed=true;Learn();
 }
 public void Correct(Guid caption,string? speaker,string newName="") {
  if(speaker!=null&&!Speakers.Contains(speaker))throw new ArgumentException("Unknown speaker.");
  var name=CleanName(newName);if(speaker==null&&name.Length==0)throw new ArgumentException("Enter a name for the new speaker.");
  var c=Captions.First(x=>x.Id==caption);Snapshot();speaker??="Person-"+Guid.NewGuid();if(name.Length>0)Names[speaker]=name;
  if(!c.Reclassified)c.DetectedSpeaker=c.Speaker;c.Speaker=speaker;c.Confirmed=true;c.Reclassified=false;Learn();
 }
 static string CleanName(string value)=>Regex.Replace(value.Trim(),@"\s+"," ")[..Math.Min(80,Regex.Replace(value.Trim(),@"\s+"," ").Length)];
 public void Undo(){if(!undo.TryPop(out var state))return;var saved=state.Item1.ToDictionary(x=>x.Id);Captions=Captions.Select(x=>saved.GetValueOrDefault(x.Id,x)).ToList();Names=state.Item2;Learn();}
 public static double? Cosine(double[] a,double[] b){if(a.Length==0||a.Length!=b.Length||a.Length>4096||a.Any(x=>!double.IsFinite(x))||b.Any(x=>!double.IsFinite(x)))return null;double aa=a.Sum(x=>x*x),bb=b.Sum(x=>x*x);return aa>1e-6&&bb>1e-6?a.Zip(b).Sum(x=>x.First*x.Second)/Math.Sqrt(aa*bb):null;}
 public void Learn(){var refs=Captions.Where(x=>x.Confirmed&&x.Speaker!=null&&x.Embedding!=null).ToList();foreach(var c in Captions.Where(x=>!x.Confirmed)){if(c.Reclassified){c.Speaker=c.DetectedSpeaker;c.Reclassified=false;}if(refs.Select(x=>x.Speaker).Distinct().Count()<2||c.Embedding==null)continue;var ranked=refs.Select(r=>(Id:r.Speaker!,Score:Cosine(c.Embedding,r.Embedding!))).Where(x=>x.Score!=null).GroupBy(x=>x.Id).Select(g=>(Id:g.Key,Score:g.Max(x=>x.Score!.Value))).OrderByDescending(x=>x.Score).ThenBy(x=>x.Id).ToArray();if(ranked.Length>=2&&ranked[0].Score>=(SpeakerModel=="precision"?.88:.82)&&ranked[0].Score-ranked[1].Score>=.12&&ranked[0].Id!=c.Speaker){c.DetectedSpeaker=c.Speaker;c.Speaker=ranked[0].Id;c.Reclassified=true;}}}
 public string Export(string format){string Time(double v){long ms=(long)Math.Round(Math.Clamp(double.IsFinite(v)?v:0,0,359999999)*1000);return $"{ms/3600000:00}:{ms/60000%60:00}:{ms/1000%60:00}{(format=="vtt"?".":",")}{ms%1000:000}";}return(format=="vtt"?"WEBVTT\n\n":"")+string.Join("\n\n",Captions.Where(c=>!string.IsNullOrWhiteSpace(c.Text)).Select((c,i)=>{var text=(c.Speaker==null?"":Name(c.Speaker)+": ")+c.Text;if(format=="txt")return text;text=text.Replace("\r"," ").Replace("\n"," ").Replace("-->","→").Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;");return $"{i+1}\n{Time(c.Start)} --> {Time(Math.Max(c.Start+.01,c.End))}\n{text}";}))+"\n";}
}
public static class ReadDocument {
 public static string Plain(string text){text=Regex.Replace(text,@"```[^\n]*\n([\s\S]*?)```","$1");text=Regex.Replace(text,@"!\[([^\]]*)\]\([^)]*\)","$1");text=Regex.Replace(text,@"\[([^\]]+)\]\([^)]*\)","$1");text=Regex.Replace(text,@"(?m)^\s{0,3}(?:#{1,6}\s+|>\s*|[-*+]\s+)","");return text.Replace("**","").Replace("__","").Replace("`","");}
 public static string[] Sentences(string text)=>Regex.Split(Plain(text),@"(?<=[.!?])\s+|\n+").Where(x=>!string.IsNullOrWhiteSpace(x)).SelectMany(x=>Enumerable.Range(0,(x.Length+1199)/1200).Select(i=>x.Substring(i*1200,Math.Min(1200,x.Length-i*1200)).Trim())).Where(x=>x.Length>0).ToArray();
}
