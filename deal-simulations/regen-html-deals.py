# Quick helper script to call run-deal.py on every tcl script in this directory and create an html page for each script
# Assumes it is run from this `deal-simulations` directory
# python regen-html-deals.py output-directory [deal-count=48]
import glob, os, subprocess, sys

args = sys.argv[1:]

assert args, "please specify the output directory"
output_directory = args[0]
assert os.path.exists(output_directory) and os.path.isdir(output_directory), "No output directory found"

deal_count = int(args[1]) if len(args) > 1 else 48

tcl_scripts = glob.glob("*.tcl")
for script in tcl_scripts:
    if "deal-utils" not in script:
        out_file = os.path.splitext(script)[0] + ".html"
        out_file_path = os.path.join(output_directory, out_file)
        cmd = f"python run-deal.py --deal-count {deal_count} --deal-script-path {script} --html-output-path {out_file_path}"

        # print(cmd)
        subprocess.check_call(cmd, shell=True)
