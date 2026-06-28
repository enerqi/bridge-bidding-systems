# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  if {[is_strong_1c north] && [hcp north]>=19 && [is_asymmetric_10_plus_two_suiter north]} { accept }
  reject
}
