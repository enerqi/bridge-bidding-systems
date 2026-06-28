# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  if {![5CM_nt north 11 13] && ([is_2c_opener north] || [is_2d_intermediate_opener north] || [is_1d_opener north])} { accept }
  reject
}
