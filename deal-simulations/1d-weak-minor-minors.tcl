# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  if {[is_1d_opener north] && [hcp south]<10 && [hcp south]>4 && ![has_side_major south] && ![flattish south] && ([hcp east]<8 || ([hearts east]<5 && [spades east]<5))} { accept }
  reject
}
