# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  if {[is_1d_opener north] && ([is_possible_wjs_1d_response south] || [is_possible_splinter_1d_response south] || [is_possible_diamond_preempt_1d_response south])} { accept }
  reject
}
