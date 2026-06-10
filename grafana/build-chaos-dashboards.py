#!/usr/bin/env python3
"""Generate 5 per-chaos-group dashboards into grafana/dashboards/Chaoses/."""

import json, os, sys

OUT_DIR = os.path.join(os.path.dirname(__file__), "dashboards", "Chaoses")
os.makedirs(OUT_DIR, exist_ok=True)

# ──────────────────────────────────────────────────────────────────────────────
# Low-level helpers
# ──────────────────────────────────────────────────────────────────────────────

DS = {"type": "prometheus", "uid": "${ds}"}

# Стиль для графиков нагрузки (workload): smooth, points, лёгкая заливка
CUSTOM_WORKLOAD = {
    "drawStyle": "line", "lineInterpolation": "smooth",
    "lineWidth": 1, "fillOpacity": 5,
    "showPoints": "auto", "pointSize": 6,
    "spanNulls": False, "gradientMode": "none",
    "stacking": {"mode": "none", "group": "A"},
    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
    "thresholdsStyle": {"mode": "off"},
    "scaleDistribution": {"type": "linear"}, "barAlignment": 0,
}

# YDB stacked: для count/rate панелей (errors, sessions, vdisks, uptime) — как в grpc.json
CUSTOM_YDB = {
    "drawStyle": "line", "lineInterpolation": "linear",
    "lineWidth": 1, "fillOpacity": 50, "barWidthFactor": 0.6,
    "showPoints": "auto", "pointSize": 1,
    "spanNulls": False, "gradientMode": "none", "insertNulls": False,
    "stacking": {"mode": "normal", "group": "A"},
    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
    "thresholdsStyle": {"mode": "off"},
    "scaleDistribution": {"type": "linear"}, "barAlignment": 0,
    "axisBorderShow": False, "axisCenteredZero": False,
    "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto",
}

# YDB lines: для latency/histogram_quantile панелей — как в queryengine.json
CUSTOM_YDB_LINES = {
    "drawStyle": "line", "lineInterpolation": "linear",
    "lineWidth": 1, "fillOpacity": 0, "barWidthFactor": 0.6,
    "showPoints": "auto", "pointSize": 1,
    "spanNulls": False, "gradientMode": "none", "insertNulls": False,
    "stacking": {"mode": "none", "group": "A"},
    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
    "thresholdsStyle": {"mode": "off"},
    "scaleDistribution": {"type": "linear"}, "barAlignment": 0,
    "axisBorderShow": False, "axisCenteredZero": False,
    "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto",
}

# node_exporter панели: без stacking, без заливки, тонкие линии
CUSTOM_NODE = {
    "drawStyle": "line", "lineInterpolation": "linear",
    "lineWidth": 1, "fillOpacity": 0,
    "showPoints": "auto", "pointSize": 3,
    "spanNulls": False, "gradientMode": "none",
    "stacking": {"mode": "none", "group": "A"},
    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
    "thresholdsStyle": {"mode": "off"},
    "scaleDistribution": {"type": "linear"}, "barAlignment": 0,
}

def target(expr, legend="", ref="A"):
    return {"datasource": DS, "expr": expr,
            "legendFormat": legend, "refId": ref}

def timeseries(id_, title, x, y, w, h, targets, *,
               unit="short", custom=None, overrides=None, extra_defaults=None):
    defaults = {"color": {"mode": "palette-classic"}, "unit": unit,
                "custom": custom if custom is not None else CUSTOM_YDB}
    if extra_defaults:
        defaults.update(extra_defaults)
    return {
        "id": id_, "type": "timeseries", "title": title,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "fieldConfig": {"defaults": defaults, "overrides": overrides or []},
        "options": {
            "tooltip": {"mode": "multi", "sort": "desc"},
            "legend": {"displayMode": "list", "placement": "bottom"},
        },
        "targets": targets,
    }

def row(id_, title, y):
    return {"id": id_, "type": "row", "title": title,
            "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1},
            "panels": []}

def annotations():
    return {"list": [
        {"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
         "enable": True, "hide": True, "iconColor": "rgba(0,211,255,1)",
         "name": "Annotations & Alerts", "type": "dashboard"},
        {"datasource": {"type": "grafana", "uid": "-- Grafana --"},
         "enable": True, "hide": False, "iconColor": "red",
         "name": "Хаосы", "tags": ["chaos"], "type": "tags"},
        {"datasource": {"type": "grafana", "uid": "-- Grafana --"},
         "enable": True, "hide": False, "iconColor": "#9E9E9E",
         "name": "Dry-хаосы", "tags": ["chaos-dry"], "type": "tags"},
    ]}

def templating():
    def var_ds():
        return {"name": "ds", "type": "datasource", "query": "prometheus",
                "label": "Datasource", "current": {}, "hide": 0}
    def var_query(name, label, q, multi=False, include_all=False):
        return {"name": name, "type": "query", "label": label,
                "datasource": DS, "query": q,
                "refresh": 2, "includeAll": include_all,
                "multi": multi, "current": {},
                "sort": 1, "hide": 0}
    return {"list": [
        var_ds(),
        var_query("database", "Database",
                  {"query": "label_values(database)", "refId": "Q"},
                  include_all=True),
        var_query("application", "Application",
                  {"query": "label_values(ydb_workload_rps, application)", "refId": "Q"},
                  include_all=True),
        var_query("scenario", "Scenario",
                  {"query": "label_values(ydb_workload_rps{application=~\"$application\"}, scenario)", "refId": "Q"},
                  multi=True, include_all=True),
    ]}

def nav_link(title, uid):
    return {
        "title": title, "type": "link", "icon": "dashboard",
        "url": f"/d/{uid}", "targetBlank": False,
        "keepTime": True, "includeVars": True,
    }

def dashboard(uid, title, tags, panels, links=None):
    return {
        "uid": uid, "title": title, "tags": tags,
        "schemaVersion": 38, "version": 1,
        "editable": True, "graphTooltip": 1,
        "time": {"from": "now-1h", "to": "now"},
        "timepicker": {},
        "refresh": "30s",
        "annotations": annotations(),
        "templating": templating(),
        "panels": panels,
        "links": links or [],
    }

def save(uid, title, tags, panels):
    slug = uid.replace("chaos-", "") + ".json"
    path = os.path.join(OUT_DIR, slug)
    with open(path, "w") as f:
        json.dump(dashboard(uid, title, tags, panels, links=_dash_links.get(uid)), f, indent=2)
    print(f"  ✓ {path}")

# ──────────────────────────────────────────────────────────────────────────────
# Reusable panel builders — (id, x, y, w, h) → panel dict
# ──────────────────────────────────────────────────────────────────────────────

def p_rps(id_, x, y, w=8, h=8):
    return timeseries(id_, "RPS", x, y, w, h, [
        target('sum by (scenario) (ydb_workload_rps{application=~"$application",scenario=~"$scenario",statut="ok"})', "{{scenario}} ok", "A"),
        target('sum by (scenario) (ydb_workload_rps{application=~"$application",scenario=~"$scenario",statut="ko"})', "{{scenario}} ko", "B"),
    ], custom=CUSTOM_WORKLOAD)

def p_error_rate(id_, x, y, w=8, h=8):
    return timeseries(id_, "Error Rate", x, y, w, h, [
        target(
            'sum by (scenario) (ydb_workload_countError{application=~"$application",scenario=~"$scenario"})'
            ' / (sum by (scenario) (ydb_workload_rps{application=~"$application",scenario=~"$scenario",statut="ok"})'
            ' + sum by (scenario) (ydb_workload_countError{application=~"$application",scenario=~"$scenario"}))',
            "{{scenario}}", "A"),
    ], unit="percentunit", custom={**CUSTOM_WORKLOAD, "softMax": 0.001})

def p_p99_latency(id_, x, y, w=8, h=8):
    return timeseries(id_, "p99 Latency by Scenario (ms)", x, y, w, h, [
        target('ydb_workload_pct99{application=~"$application",scenario=~"$scenario",statut="ok"}',
               "{{scenario}}", "A"),
    ], unit="ms", custom=CUSTOM_WORKLOAD)

def p_retries(id_, x, y, w=8, h=8):
    return timeseries(id_, "Retries", x, y, w, h, [
        target('sum by (scenario) (ydb_workload_retries{application=~"$application",scenario=~"$scenario"})',
               "{{scenario}}", "A"),
    ], custom={**CUSTOM_WORKLOAD, "softMax": 10})

# node_exporter панели
def p_cpu_by_host(id_, x, y, w=12, h=8):
    return timeseries(id_, "CPU % by host", x, y, w, h, [
        target('100-(avg by(instance)(rate(node_cpu_seconds_total{job="node",mode="idle"}[$__rate_interval]))*100)',
               "{{instance}}", "A"),
    ], unit="percent", custom=CUSTOM_NODE, extra_defaults={"min": 0})

def p_swap(id_, x, y, w=6, h=8):
    return timeseries(id_, "Swap used by hosts", x, y, w, h, [
        target('node_memory_SwapTotal_bytes{job="node"}-node_memory_SwapFree_bytes{job="node"}',
               "{{instance}}", "A"),
    ], unit="bytes", custom=CUSTOM_NODE)

def p_ydb_memory(id_, x, y, w=12, h=8):
    return timeseries(id_, "RAM used by host", x, y, w, h, [
        target('node_memory_MemTotal_bytes{job="node"} - node_memory_MemAvailable_bytes{job="node"}',
               "{{instance}}", "A"),
    ], unit="bytes", custom=CUSTOM_NODE, extra_defaults={"min": 0})

def p_disk_iops(id_, x, y, w=8, h=8):
    return timeseries(id_, "Disk IOps by host", x, y, w, h, [
        target('sum by(instance)(rate(node_disk_reads_completed_total{job="node"}[$__rate_interval]))',
               "read {{instance}}", "A"),
        target('sum by(instance)(rate(node_disk_writes_completed_total{job="node"}[$__rate_interval]))',
               "write {{instance}}", "B"),
    ], custom=CUSTOM_NODE)

def p_network_rxtx(id_, x, y, w=12, h=8):
    return timeseries(id_, "Network RX/TX by host", x, y, w, h, [
        target('sum by(instance)(rate(node_network_receive_bytes_total{job="node",device!~"lo|docker.*|veth.*|br.*"}[$__rate_interval]))',
               "rx {{instance}}", "A"),
        target('sum by(instance)(rate(node_network_transmit_bytes_total{job="node",device!~"lo|docker.*|veth.*|br.*"}[$__rate_interval]))',
               "tx {{instance}}", "B"),
    ], unit="Bps", custom=CUSTOM_NODE)

def p_tcp_connections(id_, x, y, w=12, h=8):
    return timeseries(id_, "TCP Connections (ESTABLISHED)", x, y, w, h, [
        target('node_netstat_Tcp_CurrEstab{job="node"}', "{{instance}}", "A"),
    ], custom=CUSTOM_NODE)

def p_tcp_transitions(id_, x, y, w=12, h=8):
    return timeseries(id_, "TCP Transitions (Active opens/s)", x, y, w, h, [
        target('rate(node_netstat_Tcp_ActiveOpens{job="node"}[$__rate_interval])', "active opens {{instance}}", "A"),
        target('rate(node_netstat_Tcp_PassiveOpens{job="node"}[$__rate_interval])', "passive opens {{instance}}", "B"),
    ], custom=CUSTOM_NODE)

# YDB stacked панели (count/rate: errors, sessions, vdisks, uptime)
def p_nodes_uptime(id_, x, y, w=6, h=8):
    return timeseries(id_, "Nodes Uptime", x, y, w, h, [
        target('utils_Process_UptimeSeconds{container="ydb-dynamic",database=~"$database"}', "dyn {{instance}}", "A"),
        target('utils_Process_UptimeSeconds{container="ydb-static"}', "static {{instance}}", "B"),
    ], unit="s", custom=CUSTOM_YDB)

def p_ydb_errors(id_, x, y, w=6, h=8):
    return timeseries(id_, "YDB Errors", x, y, w, h, [
        target('sum by (status) (rate(ydb_api_grpc_response_count{container="ydb-dynamic",database=~"$database",status!="SUCCESS"}[$__rate_interval]))',
               "{{status}}", "A"),
    ], custom=CUSTOM_YDB)

def p_vdisks_count(id_, x, y, w=8, h=8):
    return timeseries(id_, "VDisks count", x, y, w, h, [
        target('sum(vdisks_count)', "total", "A"),
    ], custom=CUSTOM_YDB)

def p_session_count(id_, x, y, w=12, h=8):
    return timeseries(id_, "Session count by node", x, y, w, h, [
        target('sum by (instance) (kqp_SessionActors_Active{container="ydb-dynamic",database=~"$database"})',
               "{{instance}}", "A"),
    ], custom=CUSTOM_YDB)

# YDB lines панели (histogram_quantile: latency, RTT)
def p_interconnect(id_, x, y, w=6, h=8):
    return timeseries(id_, "Interconnect Ping RTT", x, y, w, h, [
        target('histogram_quantile(0.5,  sum by (le) (rate(interconnect_PingTimeUs_bucket[$__rate_interval])))', "p50", "A"),
        target('histogram_quantile(0.95, sum by (le) (rate(interconnect_PingTimeUs_bucket[$__rate_interval])))', "p95", "B"),
        target('histogram_quantile(0.99, sum by (le) (rate(interconnect_PingTimeUs_bucket[$__rate_interval])))', "p99", "C"),
    ], unit="µs", custom=CUSTOM_YDB_LINES)

def p_rw_tx_latency(id_, x, y, w=8, h=8):
    return timeseries(id_, "RW tx server latency (ms)", x, y, w, h, [
        target('histogram_quantile(0.5,  sum by (le) (rate(ydb_table_transaction_server_duration_milliseconds_bucket{container="ydb-dynamic",database=~"$database",tx_kind="read_write"}[$__rate_interval])))', "p50", "A"),
        target('histogram_quantile(0.95, sum by (le) (rate(ydb_table_transaction_server_duration_milliseconds_bucket{container="ydb-dynamic",database=~"$database",tx_kind="read_write"}[$__rate_interval])))', "p95", "B"),
        target('histogram_quantile(0.99, sum by (le) (rate(ydb_table_transaction_server_duration_milliseconds_bucket{container="ydb-dynamic",database=~"$database",tx_kind="read_write"}[$__rate_interval])))', "p99", "C"),
    ], unit="ms", custom=CUSTOM_YDB_LINES)

def p_query_latency(id_, x, y, w=8, h=8):
    return timeseries(id_, "Query latency percentiles (ms)", x, y, w, h, [
        target('histogram_quantile(0.5,  sum by (le) (rate(ydb_table_query_execution_latency_milliseconds_bucket{container="ydb-dynamic",database=~"$database"}[$__rate_interval])))', "p50", "A"),
        target('histogram_quantile(0.95, sum by (le) (rate(ydb_table_query_execution_latency_milliseconds_bucket{container="ydb-dynamic",database=~"$database"}[$__rate_interval])))', "p95", "B"),
        target('histogram_quantile(0.99, sum by (le) (rate(ydb_table_query_execution_latency_milliseconds_bucket{container="ydb-dynamic",database=~"$database"}[$__rate_interval])))', "p99", "C"),
    ], unit="ms", custom=CUSTOM_YDB_LINES)

# ──────────────────────────────────────────────────────────────────────────────
# Dashboard builders
# ──────────────────────────────────────────────────────────────────────────────
# Layout: y=0 row "Workload", y=1 workload panels (h=8),
#         y=9 row "Ноды YDB", y=10 specific panels (h=8), y=18 second row.

_dash_links = {
    "chaos-01-02": [nav_link("← Chaos Tests", "chaos-tests")],
}

def build_01_02():
    """01, 02 – CPU, RAM"""
    panels = [
        row(1,  "Workload", 0),
        p_rps        (2,  0, 1),
        p_error_rate (3,  8, 1),
        p_p99_latency(4, 16, 1),

        row(10, "Ноды YDB", 9),
        p_cpu_by_host  (11,  0, 10, 12, 8),
        p_nodes_uptime (12, 12, 10,  6, 8),
        p_ydb_errors   (13, 18, 10,  6, 8),

        p_swap         (14,  0, 18,  6, 8),
        p_ydb_memory   (15,  6, 18, 12, 8),
        p_interconnect (16, 18, 18,  6, 8),
    ]
    save("chaos-01-02", "01, 02 – CPU, RAM",
         ["chaos", "cpu", "ram"], panels)

def build_03():
    """03 – Disk"""
    panels = [
        row(1,  "Workload", 0),
        p_rps        (2,  0, 1),
        p_error_rate (3,  8, 1),
        p_p99_latency(4, 16, 1),

        row(10, "Ноды YDB", 9),
        p_ydb_errors  (11,  0, 10, 8, 8),
        p_vdisks_count(12,  8, 10, 8, 8),
        p_disk_iops   (13, 16, 10, 8, 8),
    ]
    save("chaos-03", "03 – Disk",
         ["chaos", "disk"], panels)

def build_04_05_07():
    """04, 05, 07 – Network / tc-netem"""
    panels = [
        row(1,  "Workload", 0),
        p_rps        (2,  0, 1),
        p_error_rate (3,  8, 1),
        p_p99_latency(4, 16, 1),

        row(10, "Ноды YDB", 9),
        p_network_rxtx  (11,  0, 10, 12, 8),
        p_interconnect  (12, 12, 10, 12, 8),

        p_rw_tx_latency (13,  0, 18, 8, 8),
        p_retries       (14,  8, 18, 8, 8),
        p_ydb_errors    (15, 16, 18, 8, 8),
    ]
    save("chaos-04-05-07", "04, 05, 07 – Network / tc-netem",
         ["chaos", "network", "tc"], panels)

def build_06_11():
    """06, 11 – Network, iptables"""
    panels = [
        row(1,  "Workload", 0),
        p_rps        (2,  0, 1),
        p_error_rate (3,  8, 1),
        p_p99_latency(4, 16, 1),

        row(10, "Ноды YDB", 9),
        p_tcp_connections(11,  0, 10, 12, 8),
        p_tcp_transitions(12, 12, 10, 12, 8),

        p_session_count  (13,  0, 18, 12, 8),
        p_interconnect   (14, 12, 18, 12, 8),
    ]
    save("chaos-06-11", "06, 11 – Network, iptables",
         ["chaos", "network", "iptables"], panels)

def build_08_09_10_12():
    """08, 09, 10, 12 – Process, Services, Upgrade"""
    panels = [
        row(1,  "Workload", 0),
        p_rps        (2,  0, 1),
        p_error_rate (3,  8, 1),
        p_p99_latency(4, 16, 1),

        row(10, "Ноды YDB", 9),
        p_cpu_by_host  (11,  0, 10, 12, 8),
        p_session_count(12, 12, 10, 12, 8),

        p_ydb_errors   (13,  0, 18, 8, 8),
        p_nodes_uptime (14,  8, 18, 8, 8),
        p_query_latency(15, 16, 18, 8, 8),
    ]
    save("chaos-08-09-10-12", "08, 09, 10, 12 – Process, Services, Upgrade",
         ["chaos", "process", "upgrade"], panels)

# ──────────────────────────────────────────────────────────────────────────────

print(f"Generating dashboards → {OUT_DIR}")
build_01_02()
build_03()
build_04_05_07()
build_06_11()
build_08_09_10_12()
print("Done.")
