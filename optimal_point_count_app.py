import panel as pn
from panel.io import hold
import param

import optimal_point_count as opc

def calculate_opc(event):
    global hand_input
    global out_pane
    global conversion_pane
    raw_hand_text = hand_input.value

    hand_args = raw_hand_text.strip().split()
    summary = opc.opc_calculation(hand_args, verbose=False)
    text_report = opc.render_summary(summary, include_trick_conversion=False)

    hand_input.value = summary.hand_text_summary.replace("-", "")
    out_pane.object = text_report

    conversion_info = f"""# Optimal Points to Trick Conversions

    {opc.TRICK_CONVERSIONS_MD}
    """
    conversion_pane.object = conversion_info

hand_input = pn.widgets.TextInput(name="Hand Input", placeholder="e.g. axxx ktxx qjtxx", width=500, stylesheets=[
                    """
                    .bk-input-container > input {
                      font-size: 2rem;
                    }
                    .bk-input-group > label {
                      font-size: 2rem;
                    }
                    """
                ])
run_button = pn.widgets.Button(name="Calculate", button_type="primary", on_click=calculate_opc, stylesheets=[
                    """
                    .bk-btn-group > button {
                      font-size: 1.2rem;
                    }
                    """
                ],)
out_pane = pn.pane.Str(styles={"font-size": "1.2rem"})
conversion_pane = pn.pane.Markdown(disable_anchors=True, styles={"font-size": "1.0rem"})

main_section = [
    pn.Row(hand_input,
           run_button),
    pn.Spacer(height=30),
    pn.FlexBox(out_pane, conversion_pane)
]

def make_app_template():
    return pn.template.MaterialTemplate(
        title="Optimal Point Count Calculator",
        main=main_section,
        sidebar=[],
        sidebar_width=230,
        theme="default",
    )

# Enable dual-mode execution
if pn.state.served:
    # Served mode: `panel serve script.py`
    # need global panel install or pyproject.toml
    make_app_template().servable()
elif __name__ == "__main__":
    # Script mode: `python script.py`
    # which can avoid pyproject.toml, but LSP worse(?)
    # uv add --script script.py --python "==3.14.*" panel watchfiles
    make_app_template().show(port=5007)
