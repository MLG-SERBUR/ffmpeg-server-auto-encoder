# Preset: 10-bit x264 TFF (CRF 22)
$VIDEO_ENCODER = '-c:v libx264 -crf 22 -preset veryslow -tune film -flags +ilme+ildct -x264-params open-gop=1:tff=1 -vf setfield=tff -pix_fmt yuv422p10le -profile:v high422'
$AUDIO_ENCODER = '-c:a libopus -b:a 96k -vbr on'
$OUTPUT_SUFFIX = '-10bit'
$FINAL_EXT = '.mp4'
$MOV_FLAGS = '-movflags +faststart'
