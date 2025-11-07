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
import functools
from pprint import pprint
import re
import sys
import time

import panel as pn
from panel.io import hold
import param

import quiz


def session_key_func(request):  # tornado.httputil.HTTPServerRequest
    # EXPERIMENTAL: sticky session / mixup issues. Probably do not want to reuse sessions ( --reuse-sessions).
    # Affects how Panel reuses existing Bokeh Documents (i.e., session state) when a user reconnects or reloads the
    # page.When reusing sessions the theory is:
    # - Widget values persist across reloads.
    # - Callbacks remain active.
    # - Session-specific state (like pn.state.cache, pn.state.session_args, etc.) is preserved.
    # - Useful for long-running apps or apps with expensive initialization.
    # Reuse only works within the same browser tab and short time window. It does not persist sessions across different
    # tabs or devices. It is single proc, special server setup for sticky session routing needed with multiple processes
    # * if stay with num procs == 1 then enable automatic threading at least, but prefer to test multiple procs
    # Bokeh load balancing docs:
    # https://docs.bokeh.org/en/latest/docs/user_guide/server/deploy.html#load-balancing
    if "swedish" in request.query.lower():
        return "swedish"  # arbitrary key
    else:
        return "squad"


pn.extension(
    design="material",  # some better fonts with design material
    notifications=True,  # modal "toasts" support
    reconnect=True,
    # session_key_func=session_key_func,  # panel serve --reuse-sessions
)
pn.state.notifications.position = "center-center"

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

if "swedish" in pn.state.location.search.lower():
    title = "Swedish Club Quiz"
    bml_file = "bidding-system.bml"
    system_notes_url = "https://sublime.is/bidding-system.html"
    # theme = "dark"
    theme = "default"
else:
    title = "U16 Squad System Quiz"
    bml_file = "squad-system.bml"
    system_notes_url = "https://sublime.is/squad-system.html"
    theme = "default"

debug_enabled = pn.config.autoreload or "debug" in pn.state.location.search.lower()


# https://panel.holoviz.org/how_to/caching/manual.html
# - Imported modules are executed once when they are first imported. Objects defined in these modules are shared across
#   all user sessions!
# - The app.py script is executed each time the app is loaded. Objects defined here are shared within the single user
#   session only (unless cached).
# - Only specific, bound functions are re-executed upon user interactions, not the entire app.py script.
@pn.cache  # per server process OR per user session caching
def load_bid_sequences(bml_source: str):
    bid_tables = quiz.load_bid_tables(bml_source)
    quiz.prettify_bid_table_nodes(bid_tables)
    bid_sequences = quiz.collect_bid_table_auctions(bid_tables)
    return bid_sequences


bid_sequences = load_bid_sequences(bml_file)

INITIAL_DIFFICULTY = 5

# Global question data made into a reactive signal so that other things can change when it updates
# the alternative is to make question part of a Parameterized subclass
# Note we are currently making `Score` Parameterized as the alternative example, will experiment with how to render it
# separately to its data, but currently the `view` method is under the Score class `question.rx.value` allows us to mess
# with the underlying question class
question = param.rx(
    quiz.generate_question(
        bid_sequences, choice_type=quiz.random_multi_choice_type(), multi_choice_count=INITIAL_DIFFICULTY
    )
)

quiz_start_time_seconds = time.time()
quiz_completion_time = param.rx(None)


def quiz_still_playing() -> bool:
    return quiz_completion_time.rx.value is None


@pn.depends(question, quiz_completion_time)
def intro_view():
    if quiz_still_playing():
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
    else:
        return ""


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
    questions_correct = param.Integer(default=0, bounds=(0, None), doc="number of questions answered correctly")
    questions_attempted = param.Integer(default=0, bounds=(0, None), doc="number of questions attempted")
    streak = param.Integer(default=0, bounds=(0, None), doc="number of consecutively correct questions")
    total_points = param.Integer(default=0, bounds=(0, None), doc="points scored")

    SCORE_MILESTONES = [0.1, 0.25, 0.45, 0.65, 0.8, 1]
    POINTS_GOAL = 1000
    available_milestones = param.List(default=list(reversed(SCORE_MILESTONES)), doc="Remaining milestones to reach")

    @param.depends("questions_correct", "questions_attempted", "total_points")
    def view(self):
        if self.questions_attempted > 0:
            value = (self.questions_correct / self.questions_attempted) * 100
            percentage = round(value)
        else:
            percentage = 0
        s = f"__Score__: {self.questions_correct} / {self.questions_attempted}"

        pts = f"__Points__: {self.total_points}"

        return pn.Column(
            pn.Row(pn.pane.Markdown(s, disable_anchors=True)),
            pn.Row(
                pn.indicators.Dial(
                    # not working
                    stylesheets=[
                        """
                        .bk-CanvasPanel .bk-right {
                          background: lightblue;
                        }
                        """
                    ],
                    name="",
                    value=percentage,
                    bounds=(0, 100),
                    width=150,
                    height=150,
                    colors=[
                        (0, "#FF0000"),  # Red
                        (0.3, "#FF6600"),  # Orange-Red
                        (0.49, "#FFCC00"),  # Yellow
                        (0.59, "#99CC00"),  # Yellow-Green
                        (0.75, "#66CC00"),  # Greenish
                        (1, "#00CC00"),  # Green
                    ],
                )
            ),
            pn.Row(pn.pane.Markdown(pts, disable_anchors=True)),
            pn.Row(
                pn.indicators.LinearGauge(
                    name="",
                    value=self.total_points,
                    bounds=(0, Score.POINTS_GOAL),
                    format="",
                    colors=list(
                        zip(
                            Score.SCORE_MILESTONES,
                            [
                                "#FF0000",  # Red
                                "#FF6600",  # Orange-Red
                                "#FFCC00",  # Yellow
                                "#99CC00",  # Yellow-Green
                                "#66CC00",  # Greenish
                                "#00CC00",  # Green
                            ],
                            strict=True,
                        )
                    ),
                    show_boundaries=True,
                )
            ),
        )


class TimeBonus(param.Parameterized):
    percent_bonus = param.Integer(default=100, bounds=(0, 100), doc="percentage bonus due to answer speed")
    COLOUR_GRADES = [("dark", 17), ("secondary", 33), ("warning", 49), ("info", 65), ("success", 101)]

    def __init__(self, **params):
        super().__init__(**params)
        self._update_progress_callback = None
        self.reset()

    def update_bonus(self):
        t2 = time.time()
        t1 = self._start_time
        elapsed = t2 - t1
        left = max(self._max_time_seconds - elapsed, 0.0)
        percent_float = left / self._max_time_seconds
        self._time_left_seconds = left
        self.percent_bonus = round(percent_float * 100)

    def stop(self):
        self._update_progress_callback.stop()

    def reset(self, max_time_seconds: float = 50.0):
        self._time_left_seconds = max_time_seconds
        self._max_time_seconds = max_time_seconds
        self._start_time = time.time()
        if self._update_progress_callback:  # cleanup old callback: might be calling without actually stopping it
            self._update_progress_callback.stop()
        self._update_progress_callback = pn.state.add_periodic_callback(
            callback=functools.partial(TimeBonus.update_bonus, self=self),
            period=100,
            # docs are mixed on this, actually milliseconds
            timeout=round(max_time_seconds * 1000),
        )

    @param.depends("percent_bonus")
    def view(self):
        value = self.percent_bonus
        for colour, boundary in TimeBonus.COLOUR_GRADES:
            if value < boundary:
                new_colour = colour
                break

        return pn.Row(
            pn.indicators.Progress(
                value=value, bar_color=new_colour, sizing_mode="stretch_width", styles={"height": "2rem"}
            )
        )


# parameterized type to custom widget docs:
# https://panel.holoviz.org/how_to/param/custom.htmls
score = Score()
time_bonus = TimeBonus()


def reset_time_bonus_by_difficulty(difficulty: int = INITIAL_DIFFICULTY):
    seconds_per_level = {
        4: 8,
        5: 7,
        6: 6,
        7: 5,
        8: 4
    }
    time = difficulty * seconds_per_level.get(difficulty, 4)
    time_bonus.reset(max_time_seconds=time)


reset_time_bonus_by_difficulty()


@dataclass
class Points:
    from_candidate_lengths: int
    from_streak_bonus: int
    from_time_bonus: int


def points(question_value: quiz.Question, streak: int, percent_time_left: int) -> Points:
    from_candidate_lengths = 0
    for candidate in question_value.candidates:
        tokens_without_sep = candidate.replace("-->", "")
        tokens = tokens_without_sep.split()
        from_candidate_lengths += len(tokens)

    if streak > 1:
        percent_bonus = min(streak * 10 / 100, 1.0)
        streak_bonus = round(from_candidate_lengths * percent_bonus)
    else:
        streak_bonus = 0

    if percent_time_left > 0:
        time_bonus = round(from_candidate_lengths * (percent_time_left / 100))
    else:
        time_bonus = 0

    return Points(
        from_candidate_lengths=from_candidate_lengths, from_streak_bonus=streak_bonus, from_time_bonus=time_bonus
    )


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
    if any(button.disabled for button in ui_context.buttons):
        return  # multiple clicks occurred too quickly before server disabled the buttons

    global score
    global question
    global quiz_completion_time
    clicked_candidate = event.obj.candidate  # custom attribute added

    # disable buttons, we will create new buttons after a delay
    with hold():
        for button in ui_context.buttons:
            button.disabled = True

    time_bonus.stop()

    if clicked_candidate == question.rx.value.answer_candidate:
        score.streak += 1
        points_increase = points(question.rx.value, score.streak, time_bonus.percent_bonus)
        pn.state.notifications.success("Correct!", duration=3000)
        await asyncio.sleep(0.5)

        score.total_points += points_increase.from_candidate_lengths
        pn.state.notifications.info(f"+{points_increase.from_candidate_lengths}!", duration=3000)
        await asyncio.sleep(0.5)

        if points_increase.from_streak_bonus > 0:
            score.total_points += points_increase.from_streak_bonus
            pn.state.notifications.info(
                f"Streak {score.streak}, Bonus +{points_increase.from_streak_bonus}", duration=3000
            )
            await asyncio.sleep(0.5)

        if points_increase.from_time_bonus > 0:
            score.total_points += points_increase.from_time_bonus
            pn.state.notifications.info(f"Time Bonus +{points_increase.from_time_bonus}", duration=3000)
            await asyncio.sleep(0.5)

        with hold():
            score.questions_attempted += 1
            score.questions_correct += 1

        while score.available_milestones and score.available_milestones[-1] * score.POINTS_GOAL <= score.total_points:
            score.available_milestones.pop()
            pn.state.notifications.success("+1 SKIP!", duration=3000)
            global skips_left
            with hold():
                skips_left.rx.value += 1
                skip_button.disabled = False
            await asyncio.sleep(0.5)

        await asyncio.sleep(1.0)

        if score.total_points >= Score.POINTS_GOAL:
            quiz_completion_time.rx.value = time.time()

    else:
        with hold():
            score.streak = 0
            score.questions_attempted += 1
        pretty_answer = emoji_text_auction(question.rx.value.answer_candidate)
        pn.state.notifications.warning(f"Answer: {pretty_answer}", duration=4000)

        await asyncio.sleep(4.2)

    if quiz_still_playing():
        question.rx.value = quiz.generate_question(
            bid_sequences,
            choice_type=quiz.random_multi_choice_type(),
            multi_choice_count=difficulty_slider.value_throttled,
        )
        reset_time_bonus_by_difficulty(difficulty_slider.value_throttled)
    else:
        skip_button.disabled = True


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

suit_replace_regex = pn.state.as_cached(
    "suit_replace_regex",
    lambda: re.compile(
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
    ),
)

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


@pn.depends(question, quiz_completion_time)
def question_view():
    if not quiz_still_playing():
        return ""

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


@pn.depends(question, quiz_completion_time)
def answer_view():
    if quiz_still_playing():
        # bad name? can also emojify the answer
        answer = emoji_text_auction(question.rx.value.answer)
        leading_cap = answer[0].upper() + answer[1:]
        # markdown bold
        return pn.Row(pn.pane.Markdown(f'# "__{leading_cap}__"', styles={"font-size": "2rem"}, disable_anchors=True))
    else:
        elapsed_time = round(quiz_completion_time.rx.value - quiz_start_time_seconds, ndigits=1)
        return pn.FlexBox(
            pn.pane.Markdown(
                f"# 🎉🎉🎉\nQuiz completed in {elapsed_time} seconds!\n# 🎉🎉🎉\nWell done, now take a break...",
                styles={"font-size": "3rem"},
                disable_anchors=True,
            ),
            pn.pane.Image("./completed.jpeg", alt_text="cat sleeping next to computer mouse", width=600),
        )


def debug_button_action(event):
    pprint(question.rx.value)
    print(f"{title} ({bml_file}) from {system_notes_url}")
    pprint(pn.state.location)
    pprint(pn.state.session_info)
    print()
    pprint(pn.config)
    print()
    pprint(pn.state.cache)
    pprint(pn.state.session_args)  # seems to be query parameters
    print()
    pprint(pn.state)


debug_button = pn.widgets.Button(name="Debug", on_click=debug_button_action)


def skip_question_handler(event):
    global question
    global skips_left
    global skip_button
    if skips_left.rx.value > 0:
        with hold():
            question.rx.value = quiz.generate_question(
                bid_sequences,
                choice_type=quiz.random_multi_choice_type(),
                multi_choice_count=difficulty_slider.value_throttled,
            )
            skips_left.rx.value -= 1

    skip_button.disabled = skips_left.rx.value <= 0
    reset_time_bonus_by_difficulty(difficulty_slider.value_throttled)


skips_left = pn.rx(3)
skip_button = pn.widgets.Button(name="Skip", on_click=skip_question_handler, button_type="warning")


@pn.depends(skips_left)
def skips_left_view():
    global skips_left
    return f"{skips_left.rx.value} left"


def reset_skips_and_scoring_and_timer_and_question():
    global skip_button
    global quiz_start_time_seconds
    global quiz_completion_time

    with hold():
        skips_left.rx.value = 3
        skip_button.disabled = False
        score.questions_attempted = 0
        score.questions_correct = 0
        score.streak = 0
        score.total_points = 0
        score.available_milestones = list(reversed(Score.SCORE_MILESTONES))
        quiz_start_time_seconds = time.time()
        quiz_completion_time.rx.value = None

        reset_time_bonus_by_difficulty(difficulty_slider.value_throttled)

        question.rx.value = quiz.generate_question(
            bid_sequences,
            choice_type=quiz.random_multi_choice_type(),
            multi_choice_count=difficulty_slider.value_throttled,
        )


def restart_handler(event):
    reset_skips_and_scoring_and_timer_and_question()


restart_button = pn.widgets.Button(name="Restart", on_click=restart_handler, button_type="danger")


difficulty_slider = pn.widgets.IntSlider(
    name="Difficulty (restarts quiz!)",
    start=4,
    end=8,
    step=1,
    width=150,
    value=INITIAL_DIFFICULTY,
)


def difficulty_change(event):
    reset_skips_and_scoring_and_timer_and_question()


# imperative way, when difficulty_slider.value_throttled changes
# `value_throttled` only updates when mouse released unlike `value`
difficulty_slider.param.watch(difficulty_change, "value_throttled")

main_card_like_style = dict(
    background="seagreen",
    padding="20px",
    border_radius="25px",
    box_shadow="10px 10px rgb(255 255 255 / 70%)" if theme == "dark" else "10px 10px rgb(0 0 0 / 70%)",
)
side_section_card_style = {**main_card_like_style, "background": "lightblue"}

side_section = [
    pn.Row(pn.Column(score.view), styles=side_section_card_style),
    pn.Spacer(height=100),
    debug_button if debug_enabled else "",
    pn.Row(
        skip_button,
        skips_left_view,
        styles=side_section_card_style,
    ),
    pn.Spacer(height=100),
    pn.Row(
        pn.Column(
            difficulty_slider,
            restart_button,
        ),
        styles=side_section_card_style,
    ),
]


main_section = [
    intro_view,
    pn.Column(
        pn.FlexBox(answer_view, justify_content="center"), pn.Spacer(), question_view, styles=main_card_like_style
    ),
    pn.Spacer(height=30),
    time_bonus.view,
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


def make_app_template():
    # Should be fine to make this a global var as it's recreated per new session. In some situations we want a function
    # so we get a new object on each call, e.g. if this were to be in a different module separate to the main script
    # file that panel serve reruns per user connection.
    return pn.template.MaterialTemplate(
        title=title,
        main=main_section,
        sidebar=side_section,
        sidebar_width=230,
        theme=theme,
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
