# Run with: deal.exe [-v] -i path/to/scratch.tcl n
# The TCL interpreter annoyingly needs forward slashes in windows paths
# The main `deal.exe` program expects to run with the working directory matching the deal.exe directory
# http://bridge.thomasoandrews.com/deal30/
set script_path [ file dirname [ file normalize [ info script ] ] ]
source $script_path/deal-utils.tcl

main {
  if {[is_any_1c_opener north]
        && ([is_semi_positive_weak_two_hearts south] ||
            [is_semi_positive_majors_two_suiter south] ||
            [is_gf_hearts_minor_two_suiter south] ||
            [is_gf_majors_two_suiter south]) } { accept }
  reject
}
