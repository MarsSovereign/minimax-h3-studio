# Studio API Guide

This guide describes the current server implementation. All models use Studio's asynchronous job API; clients do not need to connect to ComfyUI or the audio.cpp child server. Use `GET /api/presets` on the running service as the source of truth for model choices, dimensions and constraints.

## 1. Base URL and conventions

```bash
# Replace this with your Studio URL.
export STUDIO_URL='http://localhost:8190'
export STUDIO_TOKEN=''   # only when the server sets H3_API_TOKEN
curl --fail-with-body "$STUDIO_URL/api/health"
curl --fail-with-body -H "Authorization: Bearer $STUDIO_TOKEN" "$STUDIO_URL/api/presets"
```

- Create jobs with `POST /api/jobs` and a form body. File uploads require `multipart/form-data`; the examples use `curl -F`.
- A successful submission returns HTTP **201** and a job object. This means the job was recorded/queued, not that inference finished. All models share one queue, and only one job runs at a time.
- Poll `GET /api/jobs/{id}` until the status is `done`, `failed` or `canceled`. Cold model loads can take time; avoid submitting duplicate jobs.
- Returned file URLs usually begin with `/files/` and are relative to the service root. Prefix them with `STUDIO_URL` when downloading.
- Authentication is optional. When the server sets `H3_API_TOKEN`, every `/api/*` request except `/api/health` must send `Authorization: Bearer <token>` (otherwise HTTP 401). `/files/*` stays open so `<video>` and `<img>` elements work; file names are random ids that only the API reveals. Model repository tokens are not Studio authentication parameters.
- Browser clients on another origin (for example an infinite-canvas page) need their origin in `H3_CORS_ORIGINS`. Listed origins get CORS headers on `/api/*` and `/files/*`, preflight for `Authorization`, and `X-Total-Count` exposed.
- The maximum request body is **256 MiB**, including files and multipart overhead. Leave room for that overhead when sizing uploads.
- File fields accept uploaded bytes, not server-local paths or URLs. To reuse a generated result, download it and upload it to the next job.
- Use `--form-string` for text to prevent curl from interpreting prompts starting with `@` or `<` as file inputs.

### Supported tasks and models

| Submission field | Model selector | Supported models | Returned `mode` |
|---|---|---|---|
| `kind=video` (default when omitted) | `lora` | MiniMax-H3 + LightX2V / larryvrh, FastH3 V2, FastH3 OmniRef | `t2v` / `i2v` / `fl2v` / `r2v` |
| `kind=image` | `image_model` | `moss`, `flux-klein-4b`, `qwen-image-21-turbo` | `t2i` / `i2i` |
| `kind=music` | None | MiniMax Music 3 | `t2m` |
| `kind=3d` | None | Pixal3D | `i23d` |
| `kind=speech` | `audio_model` | `qwen3_tts`, `voxcpm2`, `omnivoice` | `tts` |
| `kind=asr` | `audio_model` | `qwen3_asr` | `asr` |
| `POST /api/jobs/{id}/upscale` | `upscaler` | `seedvr2`, `flashvsr` | `upscale` |

`kind` selects the submission category or history filter. `mode` is a result field determined by the server from the task and its inputs. Do not submit `kind=tts` or `kind=i2v`.

### Common parameters

| Field | Description |
|---|---|
| `prompt` | Video/image prompt, music description, or text to speak. Required except for 3D and ASR. Maximum 20,000 characters in general, with a stricter 4,000-character limit for TTS. |
| `seed` | Optional integer. An empty or non-integer value produces a random seed. Video/image/music/3D seeds are reduced modulo `2^48`; speech seeds modulo `2^32`. ASR does not use a random seed to control recognition. |

Send only fields relevant to the task. Parameters such as `resolution`, `duration` and `lora` are not universal inference controls. Image and speech model settings are configured on the server.

## 2. Service health and model capabilities

| Method and path | Purpose |
|---|---|
| `GET /api/health` | Engine state, current job, queue length, model and memory management status |
| `GET /api/presets` | Available model identifiers, defaults, parameter ranges and dimensions |

`health.state` is `loading`, `ready` or `error`. `ready` means the worker can process jobs; check `running` for an active job and `queued` for the queue length. Successful job creation does not guarantee that the engine is ready yet.

`health.audio_cpp` reports the managed native child process: `running`, `model`, `backend` and `version`. Its `model` is an internal session identifier such as `qwen3_tts_clone`; **submissions still use the public identifier `audio_model=qwen3_tts`**. `loaded_models` and `unet` describe model objects/caches, not full GPU residency or proof that every required weight file has been downloaded.

Useful `presets` fields:

| Field | Contents |
|---|---|
| `resolutions`, `aspect_ratios`, `duration_range` | Video resolutions, aspect ratios and duration range |
| `groups`, `loras`, `default_loras` | Video model groups, choices and defaults; each `loras` entry includes `family`, `fixed`, supported resolutions and model information |
| `samplers`, `steps_range`, `lora_strength_range` | Video sampling parameter ranges |
| `max_refs`, `max_ref_videos` | Maximum reference image/video counts for video jobs |
| `image.choices` | Image models with their `max_refs`, `edit`, `sizes` and model configuration |
| `music`, `mesh`, `upscale` | Music duration limits, 3D options, upscalers and target dimensions |
| `speech.models`, `speech.languages`, `speech.instruction_groups` | TTS modes, voices, languages and supported OmniVoice attributes |
| `asr.models` | ASR models, timestamp options and timing sources |

## 3. Video: MiniMax-H3 / FastH3

### Model selection

Despite its name, `lora` also selects FastH3 base models that do not use a LoRA. `-sparse` choices add training-free Sol-Attn sparse attention, which roughly halves sampling time.

| `lora` | Supported inputs | Resolutions | Default steps | Sampling overrides |
|---|---|---|---|---|
| `larryvrh-v4-sparse` | Text, first frame, first + last frame | `544p` / `768p` | 4 | Fixed custom sampler / steps; sparse attention |
| `larryvrh-v4` | Text, first frame, first + last frame | `544p` / `768p` | 4 | Fixed custom sampler / steps |
| `pika-flex-fl2va-sparse-all` | Text, first frame, first + last frame | `544p` / `768p` | 6 | Fixed sampler / steps; sparse attention |
| `pika-flex-fl2va-sparse` / `pika-flex-fl2va` | Text, first frame, first + last frame | `544p` / `768p` | 6 | Fixed; sparse with a dense first step / dense |
| `pika-flex-ref2va-sparse-all` | Reference images/videos, or no references | `544p` / `768p` | 6 | Fixed sampler / steps; sparse attention |
| `pika-flex-ref2va-sparse` / `pika-flex-ref2va` | Reference images/videos, or no references | `544p` / `768p` | 6 | Fixed; sparse with a dense first step / dense |
| `fasth3-v2` | Text, first frame, first + last frame | `544p` / `768p` | 8 | Fixed sampler / steps |
| `fasth3-omniref` | Reference images/videos, or no references | `544p` / `768p` | 8 | Fixed sampler / steps |

When `lora` is omitted, ordinary video jobs default to `larryvrh-v4-sparse`. Jobs with reference images/videos default to OmniRef.

### Parameters

| Field | Default / range | Description |
|---|---|---|
| `resolution` | `768p`; `544p` / `768p` | At 16:9, 960×544 / 1344×768. Other ratios preserve approximately the same pixel area; see presets for exact sizes. |
| `duration` | 5; 2–15 seconds | Output snaps to a 17k+5 frame grid at 24 fps, so actual duration may differ slightly from the request. |
| `aspect_ratio` | `16:9` | `16:9`, `9:16`, `4:3`, `3:4`, `1:1`; with an input image or reference video, `image` follows the first input. |
| `lora` | Based on inputs and resolution | A model identifier from the table above, compatible with the input type and resolution. |
| `lora_strength` | 1; 0–2 | Rounded to two decimal places. FastH3 has no LoRA and uses 1 regardless of this field. |
| `sampler` | Model default | `euler`, `res_multistep`, `er_sde`; models with fixed sampling ignore overrides. |
| `steps` | Model default; 1–30 | FastH3 and larryvrh ignore overrides. |
| `image` | Optional file | First frame; selects `i2v`. |
| `last_image` | Optional file | Last frame; requires `image` and selects `fl2v`. |
| `ref_image` | Repeatable file, up to 6 | Reference images; selects `r2v`. Cannot be combined with first/last frames. |
| `ref_video` | Repeatable file, up to 3 | Reference videos, each at least 2 seconds; trimmed to the job duration at runtime. Selects `r2v`. |
| `audio` | Optional file | Guide audio, supported in every video mode. |
| `audio_start` | 0, in seconds | Start offset in the guide audio. Must satisfy `0 <= audio_start < audio duration - 0.5`. |

### Text to video

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=video -F resolution=768p -F duration=10 -F aspect_ratio=16:9 \
  -F lora=fasth3-v2 -F seed=42 \
  --form-string 'prompt=A red panda walks through a sunlit meadow. Wide shot, then a gentle close-up. Birds and soft instrumental music.'
```

### First frame / first + last frame

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=video -F resolution=768p -F duration=5 -F aspect_ratio=image \
  -F lora=larryvrh-v4-sparse -F 'image=@first.png' \
  --form-string 'prompt=<Picture 1> The character looks up and smiles, with a slow camera push-in.'

# For first + last frame mode, also add -F 'last_image=@last.png'.
```

`<Picture 1>` refers to the first frame and `<Picture 2>` to the last frame. The server adds required keyframe prefixes when they are missing.

### Reference images / videos

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=video -F lora=fasth3-omniref \
  -F resolution=768p -F duration=10 -F aspect_ratio=16:9 \
  -F 'ref_image=@character.png' \
  --form-string 'prompt=subject_definitions:
<Subject 1> is the adult woman in <Picture 1>.
summary:
<Subject 1> strolls beneath cherry trees. Start with a wide shot, then cut to a close-up as she smiles beside a blossom.
retention_analysis:
Keep her facial features, hairstyle and outfit consistent with <Picture 1>.
detailed_description:
Soft spring light, falling petals, natural movement.
overall_soundscape:
A gentle breeze and birds, no dialogue.
non_diegetic_music:
Quiet instrumental music.'
```

Reference images are `<Picture 1>`, `<Picture 2>`, and so on, with subjects described as `<Subject N>`. Reference videos are `<Video 1>`, `<Video 2>`, with their soundtracks as `<Audio 1>`, `<Audio 2>`. Subject numbering for video references continues after the reference images.

Add `-F 'ref_video=@motion.mp4'` to reference motion, camera work and sound. Add `-F 'audio=@guide.wav' -F audio_start=0` for guide audio. The structured prompt above is a recommended format; the backend does not assemble these semantic sections for the client.

## 4. Image generation and editing

| `image_model` | Model | Steps | Reference images |
|---|---|---|---|
| `moss` (default) | MOSS-Image | 25 | None; text-to-image only |
| `flux-klein-4b` | FLUX.2 Klein 4B distilled model | 4 | Up to 4; generation and editing |
| `qwen-image-21-turbo` | Qwen Image 2.1 Turbo | 8 | Up to 4; generation and editing |

Image parameters are `kind=image`, `image_model`, `prompt`, `aspect_ratio`, `seed`, and optional `image` / repeatable `ref_image` files for editing. The combined file count must not exceed the model's `max_refs`; `image` comes before `ref_image` inputs.

Without references, `aspect_ratio` defaults to `1:1`. With references, it defaults to `image`, following the first input. Klein editing can use another supported ratio; **Qwen editing must follow the first image, using `image` or omitting the ratio**. Output sizes are approximately 1 MP, aligned to 16 pixels for Klein/MOSS and 32 for Qwen; see presets for exact dimensions. `resolution` and `steps` do not override image model dimensions or sampling steps.

### Text to image with any of the three models

```bash
# Use moss or qwen-image-21-turbo as image_model to select another model.
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=image -F image_model=flux-klein-4b -F aspect_ratio=16:9 -F seed=42 \
  --form-string 'prompt=A young zebra in a sunlit meadow, cinematic photography.'
```

### Klein / Qwen image editing

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=image -F image_model=flux-klein-4b -F aspect_ratio=image \
  -F 'ref_image=@zebra.png' -F seed=42 \
  --form-string 'prompt=Add a red scarf around the zebra’s neck. Keep the pose and background unchanged.'

# For Qwen editing, keep the file fields and set image_model=qwen-image-21-turbo.
# For multiple inputs, repeat -F 'ref_image=@another.png' and describe their roles.
```

Download the PNG from `picture_url` when complete. Jobs with reference images have `mode=i2i`; otherwise the mode is `t2i`.

## 5. Music: MiniMax Music 3

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=music -F duration=60 -F seed=42 \
  --form-string 'prompt=Warm acoustic pop, 90 BPM, gentle female vocal, guitar and soft piano.' \
  --form-string 'lyrics=[Verse]
Morning sunlight through the trees
Petals dancing in the breeze
[Chorus]
Let this quiet moment stay'
```

`prompt` describes the style and arrangement. `lyrics` is optional, with a 20,000-character limit. `duration` defaults to 120 seconds and accepts 10–300 seconds; it is the **maximum length**, and the actual song may be shorter. Do not upload reference images, videos or guide audio. The completed job's `audio_url` points to an MP3.

## 6. Image to 3D: Pixal3D

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=3d -F 'image=@object.png' -F seed=42 \
  -F mesh_resolution=1024 -F texture_size=2048 -F remove_background=true
```

| Field | Default / range | Description |
|---|---|---|
| `image` | Required file | Exactly one input image. Do not combine it with reference images, a last frame, reference videos or audio. |
| `mesh_resolution` | 1024; 1024 / 1536 | Geometry generation resolution. |
| `texture_size` | 2048; 1024 / 2048 / 4096 | Texture size. |
| `remove_background` | `true` / `false`, default `true` | Whether to remove the input background. |
| `prompt` | Optional | A job description, not an additional text-conditioning input. |

On completion, `model_3d_url` points to a GLB and `thumb_url` to its preview image.

## 7. Speech generation, voice cloning and voice design

Speech runs through the **audio.cpp v0.9.3 CUDA server**. The public endpoint remains Studio's `POST /api/jobs`; the native service listens only on loopback and does not need direct client access.

| `audio_model` | `speech_mode=generate` | `clone` | `design` |
|---|---|---|---|
| `qwen3_tts` (default) | CustomVoice 1.7B Q8, preset voices | Base 1.7B Q8, reference audio | VoiceDesign 1.7B Q8, free-form voice description |
| `voxcpm2` | Speech generation | Reference audio | Native parenthesized description prefix |
| `omnivoice` | Speech generation | Reference audio | Supported voice attribute combinations |

### Parameters

| Field | Description |
|---|---|
| `kind` | `speech` |
| `audio_model` | An identifier from the table above. |
| `speech_mode` | `generate` (default), `clone`, `design`. |
| `prompt` | Required text to speak, up to 4,000 characters. |
| `language` | Default `auto`. Qwen supports the 10 language codes below. OmniVoice accepts a language name or ISO code. VoxCPM2 does not use this field to control inference. |
| `voice` | Qwen generate preset, default `Vivian`. Not used by other models/modes. |
| `instruction` | Voice description, required for design, up to 4,000 characters. Qwen clone does not support this field and clears it. |
| `voice_audio` | Required for clone: audio or a video with an audio track, 0.2–30 seconds. Not accepted in other modes. |
| `reference_text` | Transcript of the reference audio, up to 4,000 characters. Optional for Qwen clone, which uses speaker embedding mode when omitted. |
| `seed` | Optional; controls randomness within a model and parameter configuration. |

Qwen language codes: `zh`, `en`, `ja`, `ko`, `de`, `fr`, `ru`, `pt`, `es`, `it`, plus `auto`. Qwen voices: `Vivian`, `Serena`, `Uncle_Fu`, `Dylan`, `Eric`, `Ryan`, `Aiden`, `Ono_Anna`, `Sohee`. These presets belong to Qwen CustomVoice and cannot select a voice for another model.

### Qwen preset speech

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=speech -F audio_model=qwen3_tts -F speech_mode=generate \
  -F language=en -F voice=Ryan -F seed=42 \
  --form-string 'prompt=A gentle spring breeze carries cherry blossoms through the air.' \
  --form-string 'instruction=Speak in a warm, natural tone.'
```

For ordinary VoxCPM2 / OmniVoice generation, use the same endpoint with the corresponding `audio_model` and omit Qwen's `voice` field.

### Voice cloning (all three models)

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=speech -F audio_model=qwen3_tts -F speech_mode=clone -F language=en \
  -F 'voice_audio=@reference.wav' \
  --form-string 'reference_text=These are the words actually spoken in the reference recording.' \
  --form-string 'prompt=Hello, and welcome to our creative studio.'
```

Change `audio_model` to `voxcpm2` or `omnivoice` to use those models. The server extracts the audio track from video uploads and converts references to mono 24 kHz WAV. `reference_text` transcribes the reference; `prompt` is the new content to generate.

### Voice design

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=speech -F audio_model=qwen3_tts -F speech_mode=design -F language=en \
  --form-string 'instruction=A young adult woman with a clear voice and a calm, gentle delivery, describing a spring afternoon.' \
  --form-string 'prompt=We walk slowly along the path beneath the cherry trees.'

curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=speech -F audio_model=voxcpm2 -F speech_mode=design \
  --form-string 'instruction=A gentle, relaxed adult female voice' \
  --form-string 'prompt=May you have a quiet and beautiful afternoon.'

curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=speech -F audio_model=omnivoice -F speech_mode=design -F language=en \
  --form-string 'instruction=female, young adult, moderate pitch' \
  --form-string 'prompt=Petals drift on the breeze, and spring is all around us.'
```

The server converts VoxCPM2 instructions to its native `(description)text` prefix. OmniVoice does not accept arbitrary descriptive paragraphs: use comma-separated enum values from `presets.speech.instruction_groups`, with at most one value per group. Supported groups cover gender, age, pitch, whisper, accent and Chinese dialect, for example `female`, `young adult`, `moderate pitch`, `whisper` and `british accent`. Chinese dialect selectors retain their native model labels in presets. Attribute combinations unsuitable for the spoken language may produce poor results.

On completion, `audio_url` points to a WAV. `result.sample_rate` and `duration` describe the actual output. Speech does not guarantee per-token progress updates; `progress=0` during synthesis does not mean the job has stalled.

## 8. Transcription: Qwen3-ASR

The only supported ASR model is `qwen3_asr` (1.7B Q8). Timestamp alignment uses Qwen3 Forced Aligner 0.6B Q8. VAD is an internal dependency, not a separate model choice.

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs" \
  -F kind=asr -F audio_model=qwen3_asr -F 'media=@recording.mp4' \
  -F language=en -F timestamps=word
```

| Field | Default / range | Description |
|---|---|---|
| `media` | Required file | Audio or video with an audio track: WAV, MP3, M4A, FLAC, MP4, MOV, WebM and other PyAV-readable formats. |
| `audio_model` | `qwen3_asr` | The only ASR model. |
| `language` | `auto` | Language hint as a language name or ISO code. Presets provide common options, not the full set of ASR-supported languages. |
| `timestamps` | `word` | `none` for text only; `word` for aligned words; `segment` for subtitle display, still grouped from aligned words. |

Input recordings may be up to 2 hours long, subject to the 256 MiB request limit. Browser WebM recordings without duration metadata are supported. This endpoint transcribes **uploaded files**, not live ASR streams. The server converts input to mono 16 kHz WAV while preserving video audio start offsets and gaps, so subtitle timestamps follow the original media timeline.

Completed jobs include `result.transcript`:

```json
{
  "text": "A gentle spring breeze.",
  "language": "English",
  "duration": 3.2,
  "words": [{"start": 0.24, "end": 0.56, "text": "A"}],
  "segments": [{"start": 0.24, "end": 2.8, "text": "A gentle spring breeze."}],
  "speaker_turns": [],
  "timing_source": "forced_alignment",
  "segment_source": "grouped_aligned_words"
}
```

This structural example shows only one `words` entry; actual entries depend on the model output. All start/end values are in **seconds**. Qwen subtitle segments are grouped from real aligned words using gaps and length limits; they are not native sentence detection or speaker diarization. Both `word` and `segment` request word alignment and can produce word JSON and subtitle exports when valid spans exist. `none` produces no timestamp spans or subtitles.

`transcript_urls` contains the files actually generated:

| Key | File contents |
|---|---|
| `txt` | Plain text. |
| `json` | Text, words, subtitle segments, timing sources and the original `native` result. |
| `words` | Word-level start / end / text JSON, when aligned words exist. |
| `srt` | SRT subtitles, when real timed segments exist. |
| `vtt` | WebVTT subtitles, when real timed segments exist. |

Do not assume every recognition result has subtitles. Silence or missing valid alignment may produce only text/JSON. Both VibeVoice ASR variants have been removed and no longer accept new jobs.

## 9. Video upscaling: SeedVR2 / FlashVSR

Upscaling requires a completed Studio job with a video file; no new upload is needed.

```bash
JOB_ID='replace-with-finished-video-job-id'
curl --fail-with-body "$STUDIO_URL/api/jobs/$JOB_ID/upscale" \
  -F upscaler=flashvsr -F target=1080p -F seed=42
```

| Field | Default / range | Description |
|---|---|---|
| `upscaler` | `seedvr2`; `seedvr2` / `flashvsr` | SeedVR2 3B int8 or FlashVSR v1.1. |
| `target` | `1080p`; `1080p` / `1440p` | Target short side, preserving aspect ratio. The source short side must be smaller than the target. |
| `seed` | Optional | Upscaling seed. |

Returns **201 and a new job object**. The original job is unchanged. The new job has `mode=upscale` and `source` set to the original job ID. Poll the new ID and download its `video_url` when complete. Frame rate and audio come from the source video.

## 10. Querying, downloading, canceling and deleting jobs

### Job object

Jobs expose the following fields as applicable. Unused media fields are usually null.

| Field | Meaning |
|---|---|
| `id`, `status`, `mode` | Identifier, status and actual task mode. |
| `queue_position` | One-based queue position; usually null for jobs not queued. |
| `stage`, `progress` | Current stage and stage progress from 0 to 1, not a uniform estimate of total elapsed work. |
| `error` | Failure details. A successfully created job can still fail during execution. |
| `prompt`, `seed`, `preset` | Stored prompt, seed and resolution/upscale target. |
| `image_model`, `audio_model`, `lora` | Model choice for the corresponding task category. |
| `width`, `height`, `duration` | Output dimensions and duration, possibly null when not applicable. |
| `models`, `result.models` | Model information. Completed jobs prefer the configuration actually used for that run. |
| `video_url`, `picture_url`, `audio_url`, `model_3d_url` | Generated video, PNG, audio or GLB. |
| `thumb_url` | Thumbnail, if available. |
| `ref_urls`, `ref_video_urls`, `input_media_url` | Saved references or speech/ASR input. |
| `transcript_urls` | ASR export URL mapping. |
| `result` | Model-specific output, timings and other details; usually null before completion. |

Statuses follow `queued → running → done/failed/canceled`; queued jobs can also be canceled directly. A successful `POST .../cancel` response only acknowledges the request. For running jobs, keep polling until a terminal status appears.

### Query and download with curl

```bash
JOB_ID='replace-with-job-id'
curl --fail-with-body "$STUDIO_URL/api/jobs/$JOB_ID"

# Requires jq. Download only after status=done and the URL field is nonempty.
VIDEO_URL=$(curl --fail-with-body -sS "$STUDIO_URL/api/jobs/$JOB_ID" | jq -r '.video_url // empty')
if [ -n "$VIDEO_URL" ]; then
  curl --fail-with-body -L "$STUDIO_URL$VIDEO_URL" -o result.mp4
fi

curl --fail-with-body -X POST "$STUDIO_URL/api/jobs/$JOB_ID/cancel"
# Wait for a terminal status before deleting the record and its input/output files.
curl --fail-with-body -X DELETE "$STUDIO_URL/api/jobs/$JOB_ID"
```

Static file directories include `/files/videos/`, `pictures/`, `music/`, `speech/`, `models3d/`, `transcripts/`, `thumbs/` and `uploads/`. Prefer URLs returned by the job instead of guessing extensions or constructing paths from job IDs.

### History filters

```bash
curl --fail-with-body "$STUDIO_URL/api/jobs?kind=video&limit=20&offset=0"
curl --fail-with-body "$STUDIO_URL/api/jobs?kind=image&image_model=flux-klein-4b"
curl --fail-with-body "$STUDIO_URL/api/jobs?kind=speech&audio_model=omnivoice"
curl --fail-with-body "$STUDIO_URL/api/jobs?kind=asr&audio_model=qwen3_asr"
```

Returns a JSON array, newest first. Omit `kind` for all jobs, or use `video`, `image`, `music`, `3d`, `speech` or `asr`. The `video` category includes upscales. `image_model` requires `kind=image`; `audio_model` requires the matching `kind=speech/asr`. `limit` defaults to 60 and is clamped to 1–500; `offset` defaults to 0. The `X-Total-Count` response header gives the total matching record count.

## 11. Complete Python example

This example uses only the standard library and your existing Python environment. It creates a job, polls and downloads without uploading files. For other models, replace the form fields and output URL field.

```python
import json
import os
import time
import urllib.parse
import urllib.request

base = os.environ.get("STUDIO_URL", "http://localhost:8190").rstrip("/")

def request_json(path, fields=None):
    data = urllib.parse.urlencode(fields).encode() if fields is not None else None
    req = urllib.request.Request(base + path, data=data)
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)

job = request_json("/api/jobs", {
    "kind": "speech",
    "audio_model": "qwen3_tts",
    "speech_mode": "generate",
    "language": "en",
    "voice": "Ryan",
    "prompt": "Welcome to our creative studio.",
})
deadline = time.monotonic() + 1800
while job["status"] not in ("done", "failed", "canceled"):
    if time.monotonic() >= deadline:
        raise TimeoutError(f"Polling timed out; the job may still be running: {job['id']}")
    time.sleep(2)
    job = request_json(f"/api/jobs/{job['id']}")
if job["status"] != "done":
    raise RuntimeError(job.get("error") or job["status"])
urllib.request.urlretrieve(base + job["audio_url"], "speech.wav")
print("Saved speech.wav, job:", job["id"])
```

## 12. GPU memory management and errors

The server manages models; unloading after every request is unnecessary. Repeated jobs using the same model retain sessions/weights to reduce latency. Switching native speech models unloads the old session first. Switching between ComfyUI and native tasks coordinates GPU memory and, when necessary, stops Studio's own audio.cpp child process. Keeping models in CPU caches or mmap does not mean they occupy all GPU memory continuously.

To release the GPU for another program, wait until the queue is idle and call:

```bash
curl --fail-with-body -X POST "$STUDIO_URL/api/unload"
```

This unloads cached models/GPU memory and stops the native audio child process. The next job reloads what it needs. It returns **409** if jobs are running or queued, or **503** if the engine is not ready.

| HTTP / job status | Action |
|---|---|
| `400`, usually `{"error":"..."}` | Fix invalid parameters, input types or model/resolution combinations before resubmitting. |
| `404` | The job or file does not exist. |
| `413` | Reduce the upload size; the request body exceeds the limit. |
| `409` / `503` on unload | Wait for an idle queue / check engine health. |
| Job `failed` after HTTP 201 | Inspect `error`; possible causes include missing weights, native runtime failures, insufficient GPU memory or decoding errors. |
| Job `canceled` | Stop waiting for output. |

Not every error response is JSON; handle both HTTP status codes and response text. There are currently no idempotency keys, batch submission, WebSocket progress or live ASR endpoints. For batches, create individual jobs and save their IDs. After a network timeout, check history before resubmitting to avoid duplicates.

For model downloads, runtime installation and deployment configuration, see the [README](../README.md#native-speech-and-transcription-audiocpp). For video production, see [directing-workflow.md](directing-workflow.md).
