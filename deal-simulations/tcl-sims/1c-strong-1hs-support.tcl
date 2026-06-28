# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  if {![is_strong_1c north]} { reject }

  set south_points [hcp south]
  if {$south_points < 8 || ![has_side_major south]} { reject }

  if { ([spades north] < 3 || [spades south] < 4) && ([hearts north] < 3 || [hearts south] < 4) }  { reject }
  if {[is_any_1n_swedish_club_response south] ||
      [is_4cd_swedish_club_response south] ||
      [is_4hs_swedish_club_response south]} { reject }

  accept
}
