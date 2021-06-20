# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  set hs [hearts north]
  set ss [spades north]
  if {[hcp north] < 14 || ($hs != 6 && $ss != 6) || ![is_1major_opener north]} {reject}

  set s_hcp [hcp south]
  # some slightly positive hand?
  # if {$s_hcp <8} {reject}

  # no 4+ card support, no 2S weak jump, no 3 card 10-12 support
  if {$hs==6 && ([hearts south]>3 || ([hearts south]==3 && $s_hcp>=10 && $s_hcp<=12) || ($s_hcp < 9 && [spades south]>=7))} {reject}
  if {$ss==6 && ([spades south]>3 || ([spades south]==3 && $s_hcp>=10 && $s_hcp<=12)) } {reject}

  # no invite jump shift or stronger
  if {[clubs south]>= 6 && $s_hcp>=10} {reject}
  if {[diamonds south]>= 6 && $s_hcp>=10} {reject}
  if {[hearts south]>= 6 && $s_hcp>=10} {reject}

  accept
}
