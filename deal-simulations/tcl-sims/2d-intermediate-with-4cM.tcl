# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  set hs [hearts north]
  set ss [spades north]

  if {[is_2d_intermediate_opener north] && ($hs == 4 || $ss == 4) && [hcp south]>=6} { accept }
  reject
}
