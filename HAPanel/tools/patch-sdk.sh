#!/bin/bash
# The iPhoneOS 10.3 SDK from theos/sdks has library stubs (.tbd) that leave out armv7 symbols which
# iOS 8 really exports. Without them, linking a 32-bit app fails with "Undefined symbols".
# This adds the missing names to three stubs. Safe to run repeatedly; originals are kept as *.orig.
set -e
SDK="${THEOS:-$HOME/theos}/sdks/iPhoneOS10.3.sdk"
[ -d "$SDK" ] || { echo "SDK not found: $SDK"; exit 1; }

add() {  # add <tbd file> <symbols...>   (always rebuilt from the pristine *.orig, so re-running is harmless)
  local f="$SDK/$1"; shift
  [ -f "$f.orig" ] || cp "$f" "$f.orig"
  local list="" s
  for s in "$@"; do grep -q "$s[], ]" "$f.orig" || list="$list${list:+, }$s"; done
  cp "$f.orig" "$f"
  [ -z "$list" ] && { echo "ok       $(basename "$f")"; return; }
  sed -i "0,/^exports:/s//exports:\\n  - archs:                [ armv7, armv7s ]\\n    symbols:              [ $list ]/" "$f"
  echo "patched  $(basename "$f") (+$(echo "$list" | tr -cd , | wc -c | awk '{print $1+1}') symbols)"
}

# struct-returning message sends (CGRect, CGSize...)
add usr/lib/libobjc.tbd _objc_msgSend_stret _objc_msgSendSuper_stret _objc_msgSendSuper2_stret
# integer division and 64-bit / floating-point conversion helpers
add usr/lib/system/libcompiler_rt.tbd ___divsi3 ___udivsi3 ___modsi3 ___umodsi3 ___divmodsi4 ___udivmodsi4 \
    ___divdi3 ___udivdi3 ___moddi3 ___umoddi3 ___udivmoddi4 ___muldi3 \
    ___fixdfdi ___fixsfdi ___fixunsdfdi ___fixunssfdi ___fixunsdfsi ___fixunssfsi \
    ___floatdidf ___floatdisf ___floatundidf ___floatundisf
# setjmp/longjmp exception unwinding used by blocks and @try on armv7
add usr/lib/system/libunwind.tbd __Unwind_SjLj_Register __Unwind_SjLj_Unregister __Unwind_SjLj_Resume \
    __Unwind_SjLj_RaiseException __Unwind_SjLj_ForcedUnwind __Unwind_SjLj_Resume_or_Rethrow
