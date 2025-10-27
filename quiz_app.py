# /// script
# requires-python = ">=3.14"
# dependencies = [
#     "panel",
#     "watchfiles",
# ]
# ///
import asyncio
from dataclasses import dataclass
import dataclasses
from pprint import pprint
import re
import sys

import panel as pn
import param

import quiz


def session_key_func(request):  # tornado.httputil.HTTPServerRequest
    # - for session caching / reuse used along with panel serve --reuse-sessions
    # - our empty material template, before it is populated has the title/theme depend on the query params
    if "swedish" in request.query.lower():
        return "swedish"  # arbitrary key
    else:
        return "squad"


pn.extension(
    design="material",  # some better fonts with design material
    notifications=True,  # modal "toasts" support
    session_key_func=session_key_func,  # panel serve --reuse-sessions
)
pn.state.notifications.position = "center-center"

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

if "swedish" in pn.state.location.search.lower():
    title = "Swedish Club Quiz"
    bml_file = "bidding-system.bml"
    system_notes_url = "https://sublime.is/bidding-system.html"
    theme = "dark"
else:
    title = "U16 Squad System Quiz"
    bml_file = "squad-system.bml"
    system_notes_url = "https://sublime.is/squad-system.html"
    theme = "default"

debug_enabled = pn.config.autoreload or "debug" in pn.state.location.search.lower()


# @pn.cache  # per user session caching, pn.state.as_cached for cross session caching
# https://panel.holoviz.org/how_to/caching/manual.html
# - Imported modules are executed once when they are first imported. Objects defined in these modules are shared across
#   all user sessions!
# - The app.py script is executed each time the app is loaded. Objects defined here are shared within the single user
#   session only (unless cached).
# - Only specific, bound functions are re-executed upon user interactions, not the entire app.py script.
def load_bid_sequences(bml_source: str):
    bid_tables, header_contexts = quiz.load_bid_tables(bml_source)
    quiz.prettify_bid_table_nodes(bid_tables)
    bid_sequences = quiz.collect_bid_table_auctions(bid_tables, header_contexts)
    return bid_sequences


bid_sequences = pn.state.as_cached(
    "bid_sequences", load_bid_sequences, bml_source=bml_file
)

# Global question data made into a reactive signal so that other things can change when it updates
# the alternative is to make question part of a Parameterized subclass
# Note we are currently making `Score` Parameterized as the alternative example, will experiment with how to render it
# separately to its data, but currently the `view` method is under the Score class `question.rx.value` allows us to mess
# with the underlying question class
question = param.rx(
    quiz.generate_question(bid_sequences, choice_type=quiz.random_multi_choice_type())
)


@pn.depends(question)
def intro_view():
    question_type = question.rx.value.choice_type
    if question_type is quiz.MultiChoiceType.Auctions:
        return pn.Row(
            pn.pane.Markdown(
                "## In which auction is the *final* bid best described by:",
                disable_anchors=True,
            )
        )
    else:
        return pn.Row(
            pn.pane.Markdown(
                "## Which description matches the *final* bid in this sequence:",
                disable_anchors=True,
            )
        )


# score syncing? scores are not widgets so pn.bind seems less relevant
# `watch` seems better for side effects?
# pn.bind(myfunc, widgetref, watch=True)
# https://param.holoviz.org/user_guide/Dependencies_and_Watchers.html
# push model, handle events and go out to set stuff, e.g. UI interaction
# @param.depends() or lower level .param.watch()
# @param.depends('continent', watch=True)
#    run this function when continent changes
#    only for interrelating Parameters within Paramaterized type???
#    or probably can we depend on other, e.g. thing.param.continent
#    or thing.param to depend on all nested params within object
# @param.depends(c.param.country, d.param.i, watch=True)
#
# ok, but how to hook up button press to changing Score? just a handler I guess.
# then changes to score params triggers UI updates via dependencies
# pn.bind(update_score_next_question, button, watch=True)
# or
# pn.Row(button, pn.bind(update_score_next_question, button.param.clicks))
#
# note allow_refs between params
# https://param.holoviz.org/user_guide/References.html
#
# reactive maybe a better push type of model, more declarative
# https://param.holoviz.org/user_guide/Reactive_Expressions.html
#
# v.s
# https://param.holoviz.org/user_guide/Dynamic_Parameters.html
# pull model, e.g. call function to show the value, compute when read
# which could be read score data from some non `param` globals, perhaps
# some global time / simulation counter
#
# * higher level linking
#   https://panel.holoviz.org/how_to/links/links.html
#   including transform functions
class Score(param.Parameterized):
    questions_correct = param.Integer(
        default=0, bounds=(0, None), doc="number of questions answered correctly"
    )
    questions_attempted = param.Integer(
        default=0, bounds=(0, None), doc="number of questions attempted"
    )

    @param.depends("questions_correct", "questions_attempted")
    def view(self):
        if self.questions_attempted > 0:
            value = (self.questions_correct / self.questions_attempted) * 100
            percentage = f"{round(value)}%"
        else:
            percentage = ""
        s = f"""__Score__: {self.questions_correct} / {self.questions_attempted}

        {percentage}
        """
        return pn.pane.Markdown(s, disable_anchors=True)


# parameterized type to custom widget docs:
# https://panel.holoviz.org/how_to/param/custom.htmls
score = Score()


async def on_answer_click(event):  # event handlers can be async with no extra work
    """Event handler for question button presses that updates the score accordingly.

    Now what about changing the questions?
    Will that trigger a new view with new questions - would ideal
    prefer question data change to affect UI rather than hand cranking the UI

    (option 1) make question a param thing and render it somehow with panel

    (option 2) trigger ui updates from question as source?
        maybe cleanest way is to get something else to handle the event
        but in an event chain
        a) button_b.param.trigger('clicks')  manually trigger other widget event
        b) param.Event *inside* a Parameterized instance, thing.myevent = True triggers it
           and have something depend on the event. Convoluted?
           button onclick handler -> set obj.myevent=true
           after which we could manually mess around with the UI states
           handler could be called foo handler, agnostic of what it does (update UI)
        c) widget.param.watch(some func, ...)
           but not really controlling the order here, i.e is question yet updated

    if broadcasting events ignorant of order
        class Broadcaster(param.Parameterized):
            trigger = param.Event()

        broadcaster = Broadcaster()

        def update_table(event):
            print("Table updated!")

        def update_plot(event):
            print("Plot updated!")

        broadcaster.param.watch(update_table, 'trigger')
        broadcaster.param.watch(update_plot, 'trigger')

        # Fire both updates
        broadcaster.trigger = True

    but could also trigger it after setting the question data

    combine these ideas into a full example where clicking one button updates data and triggers another event that updates a plot

    (option 3) make question data reactive rx thing?
        `rx` provides a wrapper around Python objects, enabling the creation of
        reactive expression pipelines that dynamically update based on changes to their
        underlying parameters or widgets.

        # Global reactive data signal
        data_rx = param.rx(pd.DataFrame({"x": range(5), "y": [i**2 for i in range(5)]}))

        # UI components
        table = pn.pane.DataFrame(data_rx(), width=300, height=200)
        plot = pn.pane.HoloViews(data_rx().hvplot.line(x='x', y='y', title="Initial Plot"))

        # Widgets
        slider = pn.widgets.IntSlider(name="Size", start=1, end=50, value=5)
        update_button = pn.widgets.Button(name="Update Data", button_type="primary")

        # Bind UI updates to reactive signal
        @pn.depends(data_rx)
        def update_table(df):
            return pn.pane.DataFrame(df, width=300, height=200)

        @pn.depends(data_rx)
        def update_plot(df):
            return df.hvplot.line(x='x', y='y', title="Dynamic Plot")

        # Imperative update of global data
        def on_update(event):
            size = slider.value
            new_df = pd.DataFrame({"x": range(size), "y": [i**2 for i in range(size)]})
            data_rx(new_df)  # This triggers all reactive updates

        update_button.on_click(on_update)

        # Layout
        dashboard = pn.Column(
            pn.Row(slider, update_button),
            pn.Row(update_table, update_plot)
        )

        ------------------------
        ...or another example...
        - size_rx is the single source of truth for the size.
        - slider and size_rx are two-way bound:
        - When slider moves → size_rx updates.
        - When size_rx changes (e.g., from code) → slider updates.
        - pn.bind automatically re-renders table_view, plot_view, and status_view whenever size_rx changes.

        # Reactive global state
        size_rx = param.rx(10)

        # Widgets
        slider = pn.widgets.IntSlider(name="Size", start=1, end=100, value=size_rx())

        # Two-way binding: widget <-> signal
        slider.param.watch(lambda e: size_rx(e.new), 'value')
        size_rx.rx(slider, 'value')  # Sync signal back to widget

        # Function to generate data
        def make_data(size):
            return pd.DataFrame({"x": range(size), "y": [i**2 for i in range(size)]})

        # Bind UI components to reactive signal
        table_view = pn.bind(lambda s: pn.pane.DataFrame(make_data(s), width=300), size_rx)
        plot_view = pn.bind(lambda s: make_data(s).hvplot.line(x='x', y='y', title="Dynamic Plot"), size_rx)
        status_view = pn.bind(lambda s: f"**Current Size:** {s}", size_rx)

        # Layout
        dashboard = pn.Column(slider, pn.Row(table_view, plot_view), status_view)

    """
    global score
    global question
    clicked_candidate = event.obj.candidate  # custom attribute added

    score.questions_attempted += 1

    # disable buttons, we will create new buttons after a delay
    for button in ui_context.buttons:
        button.disabled = True

    if clicked_candidate == question.rx.value.answer_candidate:
        pn.state.notifications.success("Correct!", duration=1500)
        score.questions_correct += 1
        await asyncio.sleep(1.7)
    else:
        pretty_answer = emoji_text_auction(question.rx.value.answer_candidate)
        pn.state.notifications.warning(f"Answer: {pretty_answer}", duration=4000)
        await asyncio.sleep(4.2)

    question.rx.value = quiz.generate_question(
        bid_sequences, choice_type=quiz.random_multi_choice_type()
    )


# as there is little colour control, maybe better to use an icon image from dynamic svg with a "button icon"
# but dynamic svg too complex?
spade_emoji_black = "♠"
heart_emoji_black = "♥️"
diamond_emoji_black = "♦️"
club_emoji_black = "♣️"
spade_emoji_white = "♤"
heart_emoji_white = "♡"
diamond_emoji_white = "♢"
club_emoji_white = "♧"

suit_replace_regex = pn.state.as_cached("suit_replace_regex", lambda: re.compile(
    r"""
    \d  # a number
    (
        [CDHS]  # CDHS to replace with spans, but will have to check it's not in [] or () somehow
        #(?![^\(]*\)) # but was not inside parentheses, the link target syntax
        | # or an N (but not NT which will become NT after replacement)
        N(?!T)
    )+ # 1+ suit or N symbols to replace
    """,
    re.VERBOSE,
))

link_regex = pn.state.as_cached("link_regex", lambda: re.compile(r"\(#.*\)"))


def suit_replace(matchobj):
    text = matchobj.group(0)
    text = text.replace("C", club_emoji_black)
    text = text.replace("D", diamond_emoji_black)
    text = text.replace("H", heart_emoji_black)
    text = text.replace("S", spade_emoji_black)
    text = text.replace("N", "NT")
    return text


def emoji_text_auction(auction: str):
    a = auction

    invis_sep = "\u2063"  # silly but button is stripping excess internal whitespace
    bid_separator = f"{invis_sep * 4}‣{invis_sep * 4}"

    if auction.count("(") == 1 and auction.count(")") == 1 and "(Pass)" in auction:
        # superfluous (pass), probably better to tidy this in the data source, OR make all opposition bids explicit
        a = a.replace("(Pass)", bid_separator)

    # suits
    a = re.sub(suit_replace_regex, suit_replace, a)
    a = a.replace("!c", club_emoji_black)
    a = a.replace("!d", diamond_emoji_black)
    a = a.replace("!h", heart_emoji_black)
    a = a.replace("!s", spade_emoji_black)

    a = a.replace(" C ", f" {club_emoji_black} ")
    a = a.replace(" D ", f" {diamond_emoji_black} ")
    a = a.replace(" H ", f" {heart_emoji_black} ")
    a = a.replace(" S ", f" {spade_emoji_black} ")

    a = re.sub(r"\bC ", f"{club_emoji_black} ", a)
    a = re.sub(r"\bD ", f"{diamond_emoji_black} ", a)
    a = re.sub(r"\bH ", f"{heart_emoji_black} ", a)
    a = re.sub(r"\bS ", f"{spade_emoji_black} ", a)

    a = a.replace("Cs", f"{club_emoji_black}s")
    a = a.replace("Ds", f"{diamond_emoji_black}s")
    a = a.replace("Hs", f"{heart_emoji_black}s")
    a = a.replace("Ss", f"{spade_emoji_black}s")

    # joiner
    a = a.replace("-->", bid_separator)
    a = a.replace("--", "-")

    # link text stuff
    a = a.replace("[", "")
    a = a.replace("]", "")
    # link target remove
    a = re.sub(link_regex, "", a)

    return a


@dataclass
class UI_Context:
    buttons: list[pn.widgets.Button] = dataclasses.field(default_factory=list)


ui_context = UI_Context()


@pn.depends(question)
def question_view():
    def make_button(candidate):
        pretty_auction = emoji_text_auction(candidate)
        button = pn.widgets.Button(
            name=pretty_auction,
            button_type="primary",
            on_click=on_answer_click,
            # this would only apply above the button shadow dom
            # styles={"font-size": "2rem"},
            # sizing_mode="stretch_width",
            # annoying, `css_classes=["answer-button"]` + pn.extension(raw_css=...)
            # not useful, .answer-button custom  is on the div above the button shadow dom
            # doesn't pass through shadow dom used by material template, so have
            # to pass in a fiddly css override per button
            stylesheets=[
                """
                .bk-btn-group > button {
                  font-size: 2rem;
                }
                """
            ],
        )
        button.candidate = candidate
        return button

    buttons = [make_button(candidate) for candidate in question.rx.value.candidates]
    ui_context.buttons = buttons

    flex_pane = pn.FlexBox(
        *buttons,
        # https://panel.holoviz.org/reference/layouts/FlexBox.html
        justify_content="space-evenly",
    )
    return flex_pane


@pn.depends(question)
def answer_view():
    # bad name? can also emojify the answer
    answer = emoji_text_auction(question.rx.value.answer)
    leading_cap = answer[0].upper() + answer[1:]
    # markdown bold
    return pn.Row(
        pn.pane.Markdown(
            f'# "__{leading_cap}__"', styles={"font-size": "2rem"}, disable_anchors=True
        )
    )


# testing data binding reactivity
def debug_button_action(event):
    pprint(question.rx.value)
    print(title)
    print(bml_file)
    print(system_notes_url)
    pprint(f"cookies: {pn.state.cookies}")
    pprint(pn.state.location)
    pprint(pn.state.session_info)
    pprint(pn.config)


debug_button = pn.widgets.Button(name="Debug", on_click=debug_button_action)


def skip_question_handler(event):
    global question
    global skips_left
    global skip_button
    if skips_left.rx.value > 0:
        question.rx.value = quiz.generate_question(
            bid_sequences, choice_type=quiz.random_multi_choice_type()
        )
        skips_left.rx.value -= 1

    skip_button.disabled = skips_left.rx.value <= 0


skips_left = pn.rx(3)
skip_button = pn.widgets.Button(
    name="Skip", on_click=skip_question_handler, button_type="warning"
)


@pn.depends(skips_left)
def skips_left_view():
    global skips_left
    return f"{skips_left.rx.value} left"


def restart_handler(event):
    skips_left.rx.value = 3
    score.questions_attempted = 0
    score.questions_correct = 0
    global skip_button
    skip_button.disabled = False


restart_button = pn.widgets.Button(
    name="Restart", on_click=restart_handler, button_type="danger"
)

card_like_style = dict(
    background="seagreen",
    padding="20px",
    border_radius="25px",
    box_shadow="10px 10px rgb(255 255 255 / 70%)" if theme == "dark" else "10px 10px rgb(0 0 0 / 70%)",
)
side_section = [
    pn.Row(score.view, styles={**card_like_style, "background": "lightblue"}),
    pn.Spacer(height=100),
    debug_button if debug_enabled else "",
    pn.Row(skip_button, skips_left_view, styles={**card_like_style, "background": "lightblue"}),
    pn.Spacer(height=100),
    restart_button,
]

main_section = [
    intro_view,
    pn.Column(
        pn.FlexBox(answer_view, justify_content="center"),
        pn.Spacer(),
        question_view,
        # various base object attributes...api reference
        # https://panel.holoviz.org/api/index.html
        styles=card_like_style,
    ),
    pn.Spacer(height=100),
    """
    - Bids in brackets e.g (1♥), (bid), (any), (1NT) etc. indicate the opponents made the bid.
    - The opponents' bids are often automatically removed from the question
    - ~ means roughly/approximately (points are guides, not absolute)
    - X or Dbl means double
    - GF/FG means game forcing
    - NF means non-forcing
    - M means major, oM other major
    - m means minor, om other minor
    - Hx/HHx means Honour + x (small card), Honour Honour x etc.
    """,
    pn.Spacer(height=25),
    pn.Card(
        # contents within should naturally fit to a Card, so no need to sizing_mode="stretch_width" on HTML pane
        # pane and internal iframe need some massaging to relative sizes
        pn.pane.HTML(
            f'<iframe src="{system_notes_url}" style="width: 100%; height: 40vh"></iframe>',
            styles=dict(height="40vh", width="99%"),  # pane is 40% of viewport height
            # pane html it is 40vh high, but iframe is in a separate shadow dom
            # so setting iframe to same viewport relative spec
        ),
        collapsed=True,
        title="System Notes",
        sizing_mode="stretch_width",  # card itself needs stretching out width wise, but don't mess up height
        # styles=dict(background="skyblue")  # looks ok height width wise but influenced by pane styling
        # - setting specific height screws up the collapsed state visibility
    ),
]

template = pn.template.MaterialTemplate(
    title=title,
    main=main_section,
    sidebar=side_section,  # theme="dark"
    sidebar_width=200,
    theme=theme,
)

# Enable dual-mode execution
if pn.state.served:
    # Served mode: `panel serve script.py`
    # need global panel install or pyproject.toml
    template.servable()
elif __name__ == "__main__":
    # Script mode: `python script.py`
    # which can avoid pyproject.toml, but LSP worse(?)
    # uv add --script script.py --python "==3.14.*" panel watchfiles
    template.show(port=5007)
