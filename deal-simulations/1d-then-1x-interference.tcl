# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  set hs [hearts south]
  set ss [spades south]

  set h_e [hearts east]
  set h_w [hearts west]
  set s_e [spades east]
  set s_w [spades west]

  set h_fit [expr $h_e + $h_w]
  set s_fit [expr $s_e + $s_w]

  if {($s_fit >= 8 || $h_fit >= 8) && [hcp south]>=6  && ($hs>3 || $ss>3) && [is_1d_opener north] && ([is_1major_overcall east] || [is_1d_takeout east])} { accept }
  reject
}
