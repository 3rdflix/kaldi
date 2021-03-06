#!/usr/bin/env bash
# Copyright   2019   Ashish Arora, Vimal Manohar, Desh Raj
# Apache 2.0.
# This script is similar to the decode_diarized.sh script, except that is
# works on CSS separated audio streams. The key difference here is in how
# we create segments for feature extraction, since now they will have to
# come from the respective streams.

stage=0
nj=8
cmd=run.pl
lm_suffix=
acwt=1.0
post_decode_acwt=10.0

echo "$0 $@"  # Print the command line for logging

. ./path.sh
. utils/parse_options.sh || exit 1;

if [ $# != 6 ]; then
  echo "Usage: $0 <rttm> <in-data-dir> <lang-dir> <model-dir> <ivector-dir> <out-dir>"
  echo "e.g.: $0 data/rttm data/dev data/lang_chain exp/chain/tdnn_1a \
                 exp/nnet3_cleaned data/dev_diarized"
  echo "Options: "
  echo "  --nj <nj>                                        # number of parallel jobs."
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  exit 1;
fi

rttm=$1
data_in=$2
lang_dir=$3
asr_model_dir=$4
ivector_extractor=$5
out_dir=$6

for f in $rttm $data_in/wav.scp $data_in/text.bak \
         $lang_dir/L.fst $asr_model_dir/final.mdl; do
  [ ! -f $f ] && echo "$0: No such file $f" && exit 1;
done

if [ $stage -le 0 ]; then
  echo "$0 copying data files in output directory"
  mkdir -p ${out_dir}_hires
  cp ${data_in}/{wav.scp,utt2spk.bak} ${out_dir}_hires
  utils/data/get_reco2dur.sh ${out_dir}_hires
fi

if [ $stage -le 1 ]; then
  echo "$0 creating segments file from rttm and utt2spk, reco2file_and_channel "
  local/convert_rttm_to_utt2spk_and_segments.py --append-reco-id-to-spkr=true $rttm \
    <(awk '{print $2" "$2" "$3}' $rttm | sort -u) \
    ${out_dir}_hires/utt2spk.reco ${out_dir}_hires/segments

  # We remove the stream id from the spk id (for speaker-level CMN)
  awk '{$2=$2;sub(/_[0-9]*$/, "", $2); print}' ${out_dir}_hires/utt2spk.reco \
    > ${out_dir}_hires/utt2spk

  utils/utt2spk_to_spk2utt.pl ${out_dir}_hires/utt2spk > ${out_dir}_hires/spk2utt
  utils/fix_data_dir.sh ${out_dir}_hires
fi

if [ $stage -le 2 ]; then
  # Now we extract features
  steps/make_mfcc.sh --mfcc-config conf/mfcc_hires.conf --nj $nj --cmd "$cmd" ${out_dir}_hires
  steps/compute_cmvn_stats.sh ${out_dir}_hires
  utils/fix_data_dir.sh ${out_dir}_hires || exit 1;
  cp $data_in/text.bak ${out_dir}_hires/text
fi

if [ $stage -le 3 ]; then
  utils/mkgraph.sh \
      --self-loop-scale 1.0 $lang_dir \
      $asr_model_dir $asr_model_dir/graph${lm_suffix}
fi

if [ $stage -le 4 ]; then
  echo "$0 performing decoding on the extracted features"
  local/nnet3/decode.sh --affix 2stage --acwt $acwt --post-decode-acwt $post_decode_acwt \
    --frames-per-chunk 150 --nj $nj --ivector-dir $ivector_extractor \
    ${out_dir} $lang_dir $asr_model_dir/graph${lm_suffix} $asr_model_dir/
fi

