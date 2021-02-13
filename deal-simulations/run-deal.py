"""run-deal

Usage:
    run-deal [--deal-count=<n>] [--deal-script-path=<script_file_path>]
             [--text-output-path=<output_path>] [--deal-dir=<deal_dir>]
             [--pretty-text-output|--html-output-path=<html_file>]

Options:
    --deal-count=<n>  number of hands to generate [default: 1]
    --deal-script-path=<script_file_path>  absolute path or relative path to run-deal.py or the current directory
                                           of the deal generation script [default: scratch.tcl]
    --text-output-path=<output_path>  what file to output the generated deals into, use "-"
                                      for standard out [default: -]
    --deal-dir=<deal_dir>  folder where deal.exe is found [default: F:/bin/deal319]
    --pretty-text-output  outputs the deals in a human readable text format
    --html-output-path=<html_file>  html view of generated deals

Generates hands based on a deal (http://bridge.thomasoandrews.com/deal30/) TCL script
Each generated hand will take up one line in the output using the plain format unless using --pretty-text-output:

KQT874 K74  8743|A65 T32 AT96 J62|932 QJ65 Q42 AKQ|J A98 KJ8753 T95

north s h d c | east s h d c | south s h d c | west s h d c

Note the extra spaces when a suit is void. The purpose of outputing deals in this plain text format is to process
them and viewing them in more readable html is one post processing option that is provided here with the
html-output-path option.
"""
import os
import random
import subprocess
import sys

from docopt import docopt

this_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)))

def main():
    arguments = docopt(__doc__)
    deal_dir = arguments["--deal-dir"]
    deal_count = arguments["--deal-count"]
    deal_script = arguments["--deal-script-path"]
    text_output_path = arguments["--text-output-path"]
    pretty_text_output = bool(arguments["--pretty-text-output"])
    html_output_path = arguments["--html-output-path"]
    # print(deal_dir, deal_count, deal_script, text_output_path, pretty_text_output, html_output_path)

    if not os.path.isfile(deal_script):
        deal_script_input = deal_script
        deal_script = os.path.normpath(os.path.join(this_dir, deal_script))
        if not os.path.isfile(deal_script):
            print(f"Deal script {deal_script_input} not found", file=sys.stderr)
            sys.exit(1)

    # deal.exe's TCL interpreters needs forward slashes
    abs_script_path = os.path.abspath(deal_script)
    fslash_script_path = abs_script_path.replace('\\', '/')

    text_format_flag = "-l" if not pretty_text_output else ""

    # deal.exe -i path/to/scratch.tcl 1 -l
    cmd = f"deal.exe -i {fslash_script_path} {deal_count} {text_format_flag}"
    # print(cmd)

    # The deal.exe TCL interpreter expects its working directory to be its executable directory
    pwd = os.getcwd()
    os.chdir(deal_dir)
    try:
        complete_process = subprocess.run(cmd, shell=True, check=True, capture_output=True)
    finally:
        os.chdir(pwd)

    if text_output_path != "-":
        with open(text_output_path, "w") as f:
            f.write(complete_process.stdout.decode())
    else:
        # complete_process.returncode .stderr .stdout - captured as bytes, not str
        print(complete_process.stdout.decode())

    if html_output_path:
        text_deal_data = complete_process.stdout.decode()
        rendered_content = to_html_page(text_deal_data)
        with open(html_output_path, "w") as f:
            f.write(rendered_content)


def to_html_page(deal_text: str) -> str:
    page_template = r"""
    <!DOCTYPE html>
    <head>
        <title>Practice Deal</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link href="https://fonts.googleapis.com/css?family=Open Sans" rel="stylesheet">
        <style>
            body {
                font-family: 'Open Sans';
            }
            .content {
                margin: auto;
                max-width: 900px;
            }
            iframe {
                margin-top: 4rem;
                margin-bottom: 4rem;
            }
        </style>
    </head>
    <body class="content">
        {CONTENT}
    </body>
    """

    deal_div_template = r"""
    <div>
        <iframe src="https://www.bridgebase.com/tools/handviewer.html?{handviewer_parameters}"
        height="900px" width="900px"
        title="Random hand"
        id="hand_frame"></iframe>
    </div>
    """

    # e.g: s=sakqhakqdakqcakqj&n=s432h432d432c5432
    lines = deal_text.split("\n")
    deal_divs = []
    for index, line in enumerate(lines):
        params = parse_deal_to_handviewer_params(line, index)
        if params is not None:
            deal_divs.append(deal_div_template.format(handviewer_parameters=params))
    deal_divs_content = "\n".join(deal_divs)

    page = page_template.replace("{CONTENT}", deal_divs_content)
    return page


def parse_deal_to_handviewer_params(deal_line: str, index: int, random_vulnerability=True, random_dealer=True):
    # Turn one line of deal.exe output for a single hand into bridge base handviewer html parameters
    # KQT874 K74  8743|A65 T32 AT96 J62|932 QJ65 Q42 AKQ|J A98 KJ8753 T95
    # becomes
    # n=skqt874hk74c8743&e=sa65ht32...etc.
    # see https://www.bridgebase.com/tools/hvdoc.html
    deal_line = deal_line.strip()
    if not deal_line:
        return None

    def single_seat_param(direction_param_name, hand):
        spades, hearts, diamonds, clubs = hand.split(" ")
        return f"{direction_param_name}=s{spades}h{hearts}d{diamonds}c{clubs}"

    north, east, south, west = deal_line.split("|")
    if random_vulnerability:
        vul_query_value = random.choice(["n", "e", "b", "-"])
    else:
        vul_query_value = "-"
    if random_dealer:
        dealer_query_value = random.choice(["n", "s", "e", "w"])
    else:
        dealer_query_value = "n"

    query_params = "&".join([single_seat_param("n", north), single_seat_param("s", south),
                             single_seat_param("e", east), single_seat_param("w", west),
                             # board number, seems we need an empty auction to show it though
                             f"b={index+1}", "a=_", f"v={vul_query_value}", f"d={dealer_query_value}"])
    return query_params


if __name__ == "__main__":
    main()
