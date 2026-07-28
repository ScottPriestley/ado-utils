# Export inventory - 360sg / AEC Model Combo Project

- Dashboards exported: **9** (across 2 team(s))
- Widgets total: **129**
- Distinct queries to recreate: **77** (see queries.json; includes name-recovered)
- Query GUIDs recovered by name (had drifted): **0**
- Test Plan/Suite chart refs (not queries - migrate separately): **2**
- Still-unresolved GUIDs (need manual handling): **2**

## Widget types
| Contribution ID | Count |
|---|---|
| ms.vss-dashboards-web.Microsoft.VisualStudioOnline.Dashboards.QueryScalarWidget | 56 |
| ms.vss-dashboards-web.Microsoft.VisualStudioOnline.Dashboards.WitChartWidget | 33 |
| ms.vss-dashboards-web.Microsoft.VisualStudioOnline.Dashboards.MarkdownWidget | 25 |
| ms.vss-mywork-web.Microsoft.VisualStudioOnline.MyWork.WitViewWidget | 11 |
| ms.vss-dashboards-web.Microsoft.VisualStudioOnline.Dashboards.TcmChartWidget | 3 |
| ms.vss-dashboards-web.Microsoft.VisualStudioOnline.Dashboards.NewWorkItemWidget | 1 |

## Marketplace-extension widgets (install these extensions in the TARGET org before import)
- none - all widgets are built-in

## Recovered queries (widget GUID had drifted; matched a live Shared Query by name)
- none

## Test Plan/Suite charts (TcmChartWidget - migrate Test Plans/Suites separately, then reconfigure)
- `2d861604-08e5-41be-ac68-411a8b64f3ad` - used by: [ProServ Model Combo Project Team] FO_PO Iterations Model / PO_FO Iteration 1 Test Plan - Query Based - Chart
- `704c8adb-4b47-4298-8f5f-19a9ca9b26f9` - used by: [ProServ Model Combo Project Team] FO_PO Iterations Model / PO_FO Iteration 1 Test Plan - Query Based - Chart

## Still-unresolved GUIDs (no name match in Shared Queries - likely personal 'My Queries', deleted, or cross-project)
- `cca37372-6e94-438d-be0a-913171532da3` - used by: [ProServ Model Combo Project Team] FO_PO Iterations Model / Markdown
- `440bf7dd-9653-4aee-86cd-705886888b8d` - used by: [ProServ Model Combo Project Team] Questionnaire / Questionnaire by Area Path by State