# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  if {[is_any_1c_opener north] &&
      ([is_3n_swedish_club_resp south] || [is_4cd_swedish_club_response south] ||
       [is_4hs_swedish_club_response south]) } { accept }
  reject
}