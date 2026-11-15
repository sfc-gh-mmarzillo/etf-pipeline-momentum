"""ETF 12-1 Momentum - PoC dashboard.

Reads ONLY pipeline output tables and the pipeline run log in
ETF_MOMENTUM_POC.PIPELINE. No calculations beyond formatting.
"""

import os

import pandas as pd
import streamlit as st

DB = "ETF_MOMENTUM_POC.PIPELINE"

st.set_page_config(page_title="ETF 12-1 Momentum", layout="wide")

conn = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))


@st.cache_data(ttl=300, show_spinner=False)
def q(sql: str) -> pd.DataFrame:
    return conn.query(sql, ttl=0)


def clear_cache() -> None:
    q.clear()


head_l, head_r = st.columns([5, 1])
head_l.title("ETF 12-1 Momentum")
head_l.caption(
    "Top-16 equal-weight momentum vs 49-ETF equal-weight benchmark. "
    "Source: MOCK CapIQ XpressFeed (synthetic prices) - replace with SPGLOBAL.XPRESSFEED."
)
head_r.button("Refresh", on_click=clear_cache, use_container_width=True)

with st.spinner("Loading pipeline tables..."):
    perf = q(f"""
        SELECT PORTFOLIO, TOTAL_RETURN, ANN_RETURN, ANN_VOL, MAX_DRAWDOWN, N_MONTHS, FIRST_MONTH, LAST_MONTH
        FROM {DB}.PERF_SUMMARY""")
    growth = q(f"SELECT MONTH_END, PORTFOLIO, VALUE FROM {DB}.GROWTH ORDER BY MONTH_END")
    holdings = q(f"""
        SELECT h.MONTH_END, h.TICKER, u.GROUP_NAME, s.MOM_12_1, s.RANK, h.WEIGHT
        FROM {DB}.HOLDINGS h
        JOIN {DB}.SIGNAL s ON s.TICKER = h.TICKER AND s.MONTH_END = h.MONTH_END
        LEFT JOIN {DB}.UNIVERSE u ON u.TICKER = h.TICKER
        WHERE h.PORTFOLIO = 'MOMENTUM'
          AND h.MONTH_END = (SELECT MAX(MONTH_END) FROM {DB}.HOLDINGS)
        ORDER BY s.RANK, h.TICKER""")
    last_run = q(f"""
        SELECT RUN_ID, STATUS, STARTED_AT, ENDED_AT, CODE_VERSION, DATA_AS_OF,
               PARAMS:n_held::INT AS N_HELD, PARAMS:lookback_months::INT AS LOOKBACK,
               PARAMS:skip_months::INT AS SKIP, PARAMS:start_stage::INT AS START_STAGE
        FROM {DB}.PIPELINE_RUNS ORDER BY STARTED_AT DESC LIMIT 1""")
    stages = q(f"""
        SELECT s.STAGE_NO, s.STAGE, s.STATUS, s.ENDED_AT,
               DATEDIFF('second', s.STARTED_AT, s.ENDED_AT) AS SECONDS,
               s.ROW_COUNTS, s.CODE_SHA256, COALESCE(s.ERROR_MESSAGE, s.MESSAGE) AS DETAIL
        FROM {DB}.STAGE_RUNS s
        WHERE s.RUN_ID = (SELECT RUN_ID FROM {DB}.PIPELINE_RUNS ORDER BY STARTED_AT DESC LIMIT 1)
        QUALIFY ROW_NUMBER() OVER (PARTITION BY s.STAGE_NO ORDER BY s.ENDED_AT DESC) = 1
        ORDER BY s.STAGE_NO""")
    history = q(f"""
        SELECT r.STARTED_AT, r.STATUS, r.CODE_VERSION,
               r.PARAMS:n_held::INT AS N_HELD, r.PARAMS:start_stage::INT AS START_STAGE,
               DATEDIFF('second', r.STARTED_AT, r.ENDED_AT) AS SECONDS,
               (SELECT LISTAGG(DISTINCT STAGE, ', ') FROM {DB}.STAGE_RUNS s
                 WHERE s.RUN_ID = r.RUN_ID AND s.STATUS = 'FAILED') AS FAILED_STAGE,
               r.RUN_ID
        FROM {DB}.PIPELINE_RUNS r ORDER BY r.STARTED_AT DESC LIMIT 15""")

# ---------------------------------------------------------------- Panel 1
st.subheader("1 · Summary")
if perf.empty:
    st.info("PERF_SUMMARY is empty - run the pipeline.")
else:
    p = perf.set_index("PORTFOLIO")
    cols = st.columns(2)
    for col, name in zip(cols, ["MOMENTUM", "BENCHMARK"]):
        if name not in p.index:
            continue
        r = p.loc[name]
        with col.container(border=True):
            st.markdown(f"**{name}**  \n{r.FIRST_MONTH} → {r.LAST_MONTH} · {int(r.N_MONTHS)} months")
            a, b, c, d = st.columns(4)
            a.metric("Total return", f"{r.TOTAL_RETURN:.1%}")
            b.metric("Ann. return", f"{r.ANN_RETURN:.1%}")
            c.metric("Ann. volatility", f"{r.ANN_VOL:.1%}")
            d.metric("Max drawdown", f"{r.MAX_DRAWDOWN:.1%}")

left, right = st.columns([3, 2])

# ---------------------------------------------------------------- Panel 2
with left:
    st.subheader("2 · Growth of $1")
    if growth.empty:
        st.info("GROWTH is empty.")
    else:
        g = growth.pivot(index="MONTH_END", columns="PORTFOLIO", values="VALUE")
        st.line_chart(g, height=380)

# ---------------------------------------------------------------- Panel 3
with right:
    if holdings.empty:
        st.subheader("3 · Current holdings")
        st.info("No holdings.")
    else:
        formed = holdings["MONTH_END"].iloc[0]
        hold_month = (pd.Timestamp(formed) + pd.offsets.MonthEnd(1)).strftime("%B %Y")
        st.subheader(f"3 · Current holdings ({len(holdings)})")
        st.caption(f"Signal formed {formed} · held through {hold_month}")
        st.dataframe(
            holdings[["RANK", "TICKER", "GROUP_NAME", "MOM_12_1", "WEIGHT"]],
            hide_index=True,
            use_container_width=True,
            height=380,
            column_config={
                "MOM_12_1": st.column_config.NumberColumn("12-1 momentum", format="percent"),
                "WEIGHT": st.column_config.NumberColumn("Weight", format="percent"),
                "GROUP_NAME": "Group",
            },
        )

# ---------------------------------------------------------------- Panel 4
st.subheader("4 · Pipeline status")
if last_run.empty:
    st.info("No pipeline runs recorded yet.")
else:
    lr = last_run.iloc[0]
    ok = lr.STATUS == "SUCCEEDED"
    a, b, c, d, e = st.columns(5)
    a.metric("Last run status", f"{'✅' if ok else '❌'} {lr.STATUS}")
    b.metric("Last run (ended)", str(lr.ENDED_AT or lr.STARTED_AT)[:19])
    c.metric("Data as-of", str(lr.DATA_AS_OF))
    d.metric("Code version", lr.CODE_VERSION)
    e.metric("Params", f"{lr.LOOKBACK}-{lr.SKIP} · top {lr.N_HELD}")

    icon = {"SUCCEEDED": "✅", "FAILED": "❌", "REUSED": "♻️"}
    st.markdown("**Stages in last run** (♻️ = reused upstream table, rerun started at a later stage)")
    if stages.empty:
        st.info("No stage records for the last run.")
    else:
        s = stages.copy()
        s["STATUS"] = s["STATUS"].map(lambda x: f"{icon.get(x, '•')} {x}")
        s["ROW_COUNTS"] = s["ROW_COUNTS"].fillna("").astype(str).str.replace(r'[{}"]', "", regex=True)
        s["CODE_SHA256"] = s["CODE_SHA256"].fillna("").str[:12]
        st.dataframe(s, hide_index=True, use_container_width=True,
                     column_config={"ROW_COUNTS": "Rows per output table", "CODE_SHA256": "Code hash"})

    st.markdown("**Run history** (scheduled 1st of month 06:00 UTC + on-demand runs)")
    st.dataframe(history, hide_index=True, use_container_width=True)
