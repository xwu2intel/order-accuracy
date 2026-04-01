#!/bin/sh
set -eu

MEDIA_DIR=${MEDIA_DIR:-/media}
RTSP_PORT=${RTSP_PORT:-8554}
FFMPEG_BIN=${FFMPEG_BIN:-ffmpeg}
MEDIAMTX_BIN=${MEDIAMTX_BIN:-/opt/rtsp-streamer/mediamtx}

# Number of streams to create (one per worker/station)
NUM_STREAMS=${WORKERS:-2}

# Loop configuration
# LOOP_COUNT: number of times to play the video
#   -1 = infinite loop
#    1 = play once
#    2 = play twice, etc.
LOOP_COUNT=${LOOP_COUNT:--1}

# LOOP_WARMUP: seconds of black frames BEFORE each loop iteration (except first)
# This gives the pipeline time to "reset" and ensures the first order in each loop
# gets proper frames instead of transition frames at the loop boundary.
LOOP_WARMUP=${LOOP_WARMUP:-5}

# Source video file (use first .mp4 found, or specified by RTSP_STREAM_NAME)
SOURCE_VIDEO=${RTSP_STREAM_NAME:-}

if [ ! -d "$MEDIA_DIR" ]; then
  echo "Media directory $MEDIA_DIR does not exist" >&2
  exit 1
fi

if [ ! -x "$MEDIAMTX_BIN" ]; then
  echo "mediamtx binary $MEDIAMTX_BIN not found or not executable" >&2
  exit 1
fi

# Find the source video file
if [ -n "$SOURCE_VIDEO" ] && [ -f "$MEDIA_DIR/${SOURCE_VIDEO}.mp4" ]; then
  source_file="$MEDIA_DIR/${SOURCE_VIDEO}.mp4"
else
  # Use first .mp4 file found
  set -- "$MEDIA_DIR"/*.mp4
  if [ ! -e "$1" ]; then
    echo "No .mp4 files found in $MEDIA_DIR" >&2
    exit 1
  fi
  source_file="$1"
fi

echo "Source video: $source_file"
echo "Number of streams to create: $NUM_STREAMS"

# Get video properties for black frame generation
get_video_props() {
  video_file="$1"
  
  # Default values
  VIDEO_WIDTH=1920
  VIDEO_HEIGHT=1080
  VIDEO_FPS=30
  
  # Try to extract actual values using ffprobe if available
  if command -v ffprobe >/dev/null 2>&1; then
    width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$video_file" 2>/dev/null)
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$video_file" 2>/dev/null)
    fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$video_file" 2>/dev/null)
    
    if [ -n "$width" ] && [ "$width" -gt 0 ] 2>/dev/null; then
      VIDEO_WIDTH="$width"
    fi
    if [ -n "$height" ] && [ "$height" -gt 0 ] 2>/dev/null; then
      VIDEO_HEIGHT="$height"
    fi
    if [ -n "$fps" ]; then
      # fps might be a fraction like "30/1", extract numerator
      VIDEO_FPS=$(echo "$fps" | cut -d'/' -f1)
    fi
  else
    # Fallback to parsing ffmpeg output
    props=$("$FFMPEG_BIN" -i "$video_file" 2>&1 | grep -E "Video:" | head -1)
    
    # Extract resolution (looking for pattern like "1920x1080" or "640x480")
    if echo "$props" | grep -qoE ", [0-9]+x[0-9]+"; then
      res=$(echo "$props" | sed -n 's/.*[^0-9]\([0-9]\{3,4\}x[0-9]\{3,4\}\).*/\1/p')
      if [ -n "$res" ]; then
        w=$(echo "$res" | cut -dx -f1)
        h=$(echo "$res" | cut -dx -f2)
        if [ "$w" -gt 100 ] 2>/dev/null && [ "$h" -gt 100 ] 2>/dev/null; then
          VIDEO_WIDTH="$w"
          VIDEO_HEIGHT="$h"
        fi
      fi
    fi
  fi
  
  echo "Video properties: ${VIDEO_WIDTH}x${VIDEO_HEIGHT} @ ${VIDEO_FPS}fps"
}

# Create a looped video file with black warmup segments between loops
# This keeps the stream continuous (no disconnects) while adding warmup periods
create_looped_video() {
  video_file="$1"
  loop_count="$2"
  warmup_sec="$3"
  output_file="$4"
  
  echo "Creating looped video with ${warmup_sec}s warmup between ${loop_count} loops..."
  
  # Get video properties
  get_video_props "$video_file"
  
  # Create concat list file
  concat_list="/tmp/concat_list_$$.txt"
  
  # Use different variable name to avoid conflict with outer loop's 'i'
  loop_idx=1
  while [ $loop_idx -le $loop_count ]; do
    # Add black warmup BEFORE each loop (except the first one)
    if [ $loop_idx -gt 1 ] && [ "$warmup_sec" -gt 0 ]; then
      echo "file '/tmp/black_warmup.mp4'" >> "$concat_list"
    fi
    echo "file '$video_file'" >> "$concat_list"
    loop_idx=$((loop_idx + 1))
  done
  
  # Generate black warmup video if needed
  if [ "$warmup_sec" -gt 0 ] && [ "$loop_count" -gt 1 ]; then
    echo "Generating ${warmup_sec}s black warmup segment..."
    
    # Get codec info from source video for better compatibility
    video_codec=$("$FFMPEG_BIN" -i "$video_file" 2>&1 | grep -E "Stream.*Video" | grep -oE "h264|hevc|h265|mpeg4" | head -1)
    video_codec=${video_codec:-h264}
    
    "$FFMPEG_BIN" -y \
      -f lavfi \
      -i "color=c=black:s=${VIDEO_WIDTH}x${VIDEO_HEIGHT}:r=${VIDEO_FPS}:d=${warmup_sec}" \
      -f lavfi \
      -i "anullsrc=r=48000:cl=stereo" \
      -t "$warmup_sec" \
      -c:v libx264 -preset ultrafast -tune zerolatency \
      -profile:v baseline -level 3.0 \
      -c:a aac -b:a 128k \
      -pix_fmt yuv420p \
      /tmp/black_warmup.mp4 2>/dev/null || \
    "$FFMPEG_BIN" -y \
      -f lavfi \
      -i "color=c=black:s=${VIDEO_WIDTH}x${VIDEO_HEIGHT}:r=${VIDEO_FPS}:d=${warmup_sec}" \
      -t "$warmup_sec" \
      -c:v libx264 -preset ultrafast -tune zerolatency \
      -pix_fmt yuv420p \
      /tmp/black_warmup.mp4 2>/dev/null
    
    if [ ! -f /tmp/black_warmup.mp4 ]; then
      echo "WARNING: Failed to create black warmup segment, will proceed without warmup"
      rm -f "$concat_list"
      return 1
    fi
    echo "Black warmup segment created"
  fi
  
  # Concatenate using concat demuxer
  # Try -c copy first (fast), fall back to re-encoding if it fails
  echo "Concatenating videos..."
  if ! "$FFMPEG_BIN" -y \
    -f concat \
    -safe 0 \
    -i "$concat_list" \
    -c copy \
    "$output_file" 2>/dev/null; then
    echo "Fast concat failed, trying with re-encoding..."
    if ! "$FFMPEG_BIN" -y \
      -f concat \
      -safe 0 \
      -i "$concat_list" \
      -c:v libx264 -preset fast -crf 18 \
      -c:a aac -b:a 128k \
      "$output_file" 2>/dev/null; then
      echo "WARNING: concat failed, will proceed without warmup"
      rm -f "$concat_list"
      return 1
    fi
  fi
  
  rm -f "$concat_list"
  
  if [ ! -f "$output_file" ]; then
    echo "WARNING: Failed to create looped video, will proceed without warmup"
    return 1
  fi
  
  echo "Looped video created: $output_file"
  return 0
}

# Function to stream video with loop warmup support
stream_video() {
  stream_name="$1"
  
  echo "RTSP stream: $stream_name (LOOP_COUNT=$LOOP_COUNT, LOOP_WARMUP=${LOOP_WARMUP}s)" 1>&2
  
  cmds=()
  if [ "$LOOP_COUNT" = "-1" ]; then
    # Infinite loop mode - use simple -stream_loop
    # Note: No warmup in infinite mode (would require complex filter)
    # LOW-LATENCY FLAGS for faster client connection
    echo "Using infinite loop mode (no warmup, low-latency)" 1>&2
    cmds=(
      "$FFMPEG_BIN"
      -hide_banner 
      -loglevel warning 
      -fflags nobuffer 
      -flags low_delay 
      -re 
      -ss 0 
      -stream_loop -1 
      -i "$source_file" 
      -c copy
      -rtsp_transport tcp
      -flush_packets 1
      -f rtsp
      "rtsp://127.0.0.1:${RTSP_PORT}/${stream_name}"
    )
  elif [ "$LOOP_COUNT" = "1" ]; then
    # Single play - force seek to beginning with -ss 0
    # LOW-LATENCY FLAGS + VIDEO LEADER:
    # - Add 30 seconds of black frames at start to give GStreamer time to connect
    # - This accounts for: initial connection (~2s) + potential restart (~2s) + OCR warmup (~10s) + buffer
    # - This ensures order 384 (at second 2) is captured even with pipeline restart
    # - fflags nobuffer: No output buffering
    # - flags low_delay: Enable low-delay mode
    # - flush_packets 1: Flush packets immediately
    low_latency_file="/tmp/low_latency_video_${stream_name}.mp4"
    if create_low_latency_video "$source_file" "$low_latency_file" 1>&2 && [ -f "$low_latency_file" ]; then
      echo "Using single play mode with 30s leader (low-latency)" 1>&2
      cmds=(
        "$FFMPEG_BIN"
        -hide_banner
        -loglevel warning
        -re
        -ss 0
        -i "$low_latency_file"
        -c copy
        -rtsp_transport tcp
        -flush_packets 1
        -f rtsp
        "rtsp://127.0.0.1:${RTSP_PORT}/${stream_name}"
      )
    fi
  else
    # Finite loop with warmup - try to create pre-concatenated video
    looped_file="/tmp/looped_video_${stream_name}.mp4"
    
    if create_looped_video "$source_file" "$LOOP_COUNT" "$LOOP_WARMUP" "$looped_file" 1>&2 && [ -f "$looped_file" ]; then
      echo "Streaming pre-looped video with warmup" 1>&2
      cmds=(
        "$FFMPEG_BIN"
        -hide_banner
        -loglevel warning
        -re
        -i "$looped_file"
        -c copy
        -rtsp_transport tcp
        -f rtsp
        "rtsp://127.0.0.1:${RTSP_PORT}/${stream_name}"
      )
    else
      # Fallback to simple -stream_loop without warmup
      echo "Falling back to simple loop mode (no warmup)" 1>&2
      stream_loop_val=$((LOOP_COUNT - 1))
      cmds=(
        "$FFMPEG_BIN"
        -hide_banner
        -loglevel warning
        -re
        -stream_loop $stream_loop_val
        -i "$source_file"
        -c copy
        -rtsp_transport tcp
        -f rtsp
        "rtsp://127.0.0.1:${RTSP_PORT}/${stream_name}"
      )
    fi
  fi
  echo "${cmds[@]}"
}

create_low_latency_video () {
  source_file="$1"
  output_file="$2"

  # Get video dimensions for black frame generation
  video_dim=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$source_file" 2>/dev/null)
  video_width=$(echo "$video_dim" | cut -d',' -f1)
  video_height=$(echo "$video_dim" | cut -d',' -f2)
  video_width=${video_width:-1280}
  video_height=${video_height:-720}

  "$FFMPEG_BIN"
    -hide_banner
    -loglevel warning
    -f lavfi -i "color=c=black:s=${video_width}x${video_height}:r=30:d=30"
    -re
    -ss 0
    -i "$source_file"
    -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0[outv]"
    -map "[outv]"
    -c:v libx264 -preset ultrafast -tune zerolatency
    -fflags nobuffer
    -flags low_delay
    -rtsp_transport tcp
    -flush_packets 1
    -f rtsp
    "$output_file"
}

# Function to start all video streams
configure_all_streams() {
  echo "Configuring all $NUM_STREAMS RTSP streams..."
  
  config_file=$1
  if [ -n "${RTSP_STREAMS:-}" ]; then
    # Use custom stream names from RTSP_STREAMS
    stream_names=$(echo "$RTSP_STREAMS" | tr ',' ' ')
    i=0
    for stream_name in $stream_names; do
      i=$((i + 1))
      [ $i -le $NUM_STREAMS ] || break
      echo "  $stream_name:" >> "$config_file"
      echo "    runOnDemand: $(stream_video $stream_name)" >> "$config_file"
      echo "    runOnDemandCloseAfter: 5s" >> "$config_file"
    done
  else
    # Create station_N streams
    i=1
    while [ $i -le $NUM_STREAMS ]; do
      stream_name="station_${i}"
      echo "  $stream_name:" >> "$config_file"
      echo "    runOnDemand: $(stream_video $stream_name)" >> "$config_file"
      echo "    runOnDemandCloseAfter: 5s" >> "$config_file"
      i=$((i + 1))
    done
  fi
}

# Create streams for each station
# If RTSP_STREAMS is set (comma-separated), use those names
# Otherwise create station_1, station_2, etc.
configure_all_streams /opt/rtsp-streamer/mediamtx.yml

# Start mediamtx
"$MEDIAMTX_BIN"


