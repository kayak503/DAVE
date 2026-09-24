namespace LocalVoice;

public static class ModelGuidance
{
 public static string Acceleration(Model model)=>model.Task=="stt"?"NVIDIA GPU + CPU fallback":model.Task=="tts"?"CPU voice":"CPU";
 public static string Recommendation(Model model)
 {
  if(model.Task=="tts")return model.Id.Contains("kokoro")?"Expressive reading · good starting point for natural voices. Runs on CPU; your GPU does not speed up this voice.":"Local reading voice · runs on CPU. Try Windows System Voice for immediate playback.";
  if(model.Task!="stt")return model.Description??"Optional local wording suggestions.";
  if(model.Id.Contains("tiny"))return "Fastest dictation · lightest option for CPU. All recognition models can also use your NVIDIA GPU.";
  if(model.Id.Contains("base"))return "Quick everyday dictation · a step up from Tiny with modest memory use.";
  if(model.Id.Contains("small"))return "Balanced accuracy and speed · recommended starting point for conversations on CPU or GPU.";
  if(model.Id.Contains("turbo"))return "Recommended for GPU transcription · faster than full Large, with strong recognition accuracy.";
  if(model.Id.Contains("large"))return "Highest recognition tier · more memory and processing time. A dedicated NVIDIA GPU is recommended.";
  return "Higher accuracy with more processing time · NVIDIA GPU recommended for longer recordings.";
 }
 public static string Hardware(IReadOnlyList<GpuDevice> devices,string preference)
 {
  if(devices.Count==0)return "No supported NVIDIA GPU detected · recognition will use CPU in Automatic mode.";
  var selected=preference=="auto"?devices.OrderByDescending(g=>g.MemoryMB).First():devices.FirstOrDefault(g=>g.Id==preference);
  if(selected==null)return "Your selected GPU is unavailable · Automatic mode will use CPU. Choose another GPU in Settings.";
  return $"{selected.Name} · {selected.MemoryMB/1024d:0.#} GB dedicated memory · available for dictation and transcription";
 }
}
