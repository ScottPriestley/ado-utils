"""Minimal mock of the Azure DevOps REST endpoints used by ado-extract-workitems.ps1.

Usage: python3 mock_ado_server.py <port>
Org: contoso, project: "Fit Gap", PAT: testpat. Behaviour mirrors documented API contracts:
WIQL $top paging, workitemsbatch (max 200, $expand xor fields, errorPolicy omit),
comments paging via continuationToken, 401 for bad PAT, 404 JSON for unknown project.
Injects one 429 (Retry-After: 1) and one 503 to exercise retries.
"""
import base64
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

ORG = "contoso"
PROJECT = "Fit Gap"
PAT = "testpat"
CALLS = []
INJECT = {"429": True, "503": True}


def f(ref, name, typ="string", identity=False):
    return {"referenceName": ref, "name": name, "type": typ, "isIdentity": identity}


FIELDS = [
    f("System.Id", "ID", "integer"),
    f("System.WorkItemType", "Work Item Type"),
    f("System.State", "State"),
    f("System.AreaPath", "Area Path", "treePath"),
    f("System.IterationPath", "Iteration Path", "treePath"),
    f("System.CreatedDate", "Created Date", "dateTime"),
    f("System.CreatedBy", "Created By", "string", True),
    f("System.ChangedDate", "Changed Date", "dateTime"),
    f("System.ChangedBy", "Changed By", "string", True),
    f("System.Title", "Title"),
    f("System.Description", "Description", "html"),
    f("System.AssignedTo", "Assigned To", "string", True),
    f("System.CommentCount", "Comment Count", "integer"),
    f("System.TeamProject", "Team Project"),
    f("Microsoft.VSTS.Common.AcceptanceCriteria", "Acceptance Criteria", "html"),
    f("Microsoft.VSTS.Scheduling.DueDate", "Due Date", "dateTime"),
    f("Microsoft.VSTS.Common.Priority", "Priority", "integer"),
    f("Custom.Area", "Area"),  # collides with column name "Area" -> should warn, keep System.AreaPath
    f("Custom.GapDescription", "Gap Description", "html"),
    f("Custom.DesiredBusinessOutcome", "Desired Business Outcome", "html"),
    f("Custom.OptionsConsidered", "Options Considered", "html"),
    f("Custom.ProsCons", "Pros/Cons of all Options", "html"),
    f("Custom.HSORecommendedSolution", "HSO Recommended Solution", "html"),
    f("Custom.AVISPLRecommendedSolution", "AVI-SPL Recommended Solution", "html"),
    f("Custom.WorkItemStatus", "Work Item Status"),
    f("Custom.FitGapAssessment", "Fit Gap Assessment"),
    f("Custom.SMERequestTShirtSize", "SME Request T-Shirt Size"),  # normalized match
    f("Custom.HSOSolutionTeeshirtSize", "HSO Solution Teeshirt Size"),
    f("Custom.GapClosure", "Gap Closure"),
    f("Custom.Wave", "Wave"),
    f("Custom.CENewFieldRequest", "CE New Field Request"),
    # "Identified When" intentionally missing -> UNRESOLVED (test maps it via -FieldMap)
    f("Custom.WhenIdentified", "When Identified"),
    f("Custom.ChangeOrderRequired", "Change Order Required", "boolean"),
    f("Custom.ChangeOrderNumber", "Change Order Number"),
    f("Custom.TimelineImpact", "Timeline Impact"),
    # "Development" intentionally missing -> falls back to development links
    f("Custom.DualWriteImpact", "Dual Write Impact"),
    f("Custom.TeeshirtSize", "Teeshirt Size"),
    f("Custom.Answer", "Answer", "html"),
    f("Custom.ClientTeamLead", "Client Team Lead", "string", True),
    f("Custom.HSOConsultant", "HSO Consultant", "string", True),
    f("Custom.WorkshopNumber", "Workshop Number", "integer"),
    f("Custom.WorkshopDate", "Workshop Date", "dateTime"),
    f("Custom.OCMImpact", "OCM Impact"),
    f("Custom.ServiceImpact", "Service Impact"),
    f("Custom.CrossFunctionalImpact", "Cross-Functional Impact"),  # normalized match
    f("Custom.CrossFunctionalImpactDetails", "Cross Functional Impact Details", "html"),
    f("Custom.Responsible", "Responsible"),
]


def ident(name):
    return {"displayName": name, "uniqueName": name.lower().replace(" ", ".") + "@contoso.com", "id": "00000000-0000-0000-0000-000000000001"}


BASE = f"http://localhost/{ORG}/_apis/wit/workItems/"


def wi(i, wtype, title, extra=None, relations=None, comments=0, project=PROJECT):
    fields = {
        "System.Id": i,
        "System.WorkItemType": wtype,
        "System.State": "New",
        "System.AreaPath": f"{PROJECT}\\Finance",
        "System.IterationPath": f"{PROJECT}\\Wave 1",
        "System.CreatedDate": "2026-01-15T14:30:00.123Z",
        "System.CreatedBy": ident("Ana López"),
        "System.ChangedDate": "2026-02-01T09:05:00Z",
        "System.ChangedBy": ident("Bob Smith"),
        "System.Title": title,
        "System.CommentCount": comments,
        "System.TeamProject": project,
    }
    fields.update(extra or {})
    return {"id": i, "rev": 3, "fields": fields, "relations": relations or [], "url": BASE + str(i)}


def rel(rel_type, target=None, url=None, name=None, comment=None):
    attrs = {"isLocked": False}
    if name:
        attrs["name"] = name
    if comment:
        attrs["comment"] = comment
    return {"rel": rel_type, "url": url or BASE + str(target), "attributes": attrs}


WORK_ITEMS = {
    1: wi(1, "Requirement", "GL posting — multi-currency", {
        "System.Description": "<div><p>Line one &amp; more</p><ul><li>Bullet A</li><li>Bullet B</li></ul>"
                              "<p>See <a href=\"https://contoso.sharepoint.com/doc\">spec</a></p></div>",
        "System.AssignedTo": ident("Chen Wei"),
        "Custom.Area": "Finance-custom",
        "Custom.GapDescription": "<b>Gap</b><br/>second line",
        "Custom.ProsCons": "=SUM(A1:A2)",
        "Custom.SMERequestTShirtSize": "M",
        "Custom.HSOSolutionTeeshirtSize": "L",
        "Custom.ChangeOrderRequired": True,
        "Custom.WhenIdentified": "Workshop 3",
        "Custom.ClientTeamLead": ident("Dana Client"),
        "Custom.WorkshopNumber": 3,
        "Custom.WorkshopDate": "2026-03-10T05:00:00Z",
        "Microsoft.VSTS.Scheduling.DueDate": "2026-04-30T00:00:00Z",
        "Microsoft.VSTS.Common.Priority": 2,
        "Custom.CrossFunctionalImpact": "Yes",
        "Custom.Responsible": "HSO",
    }, [
        rel("System.LinkTypes.Hierarchy-Reverse", 10, name="Parent"),
        rel("System.LinkTypes.Related", 900, name="Related", comment="cross-project"),
        rel("System.LinkTypes.Related", 5),  # no attributes.name -> resolved via relation types API
        rel("Hyperlink", url="https://contoso.sharepoint.com/fitgap.xlsx"),
        rel("AttachedFile", url="http://localhost/contoso/_apis/wit/attachments/abc", name="file.png"),
        rel("ArtifactLink", url="vstfs:///Git/PullRequestId/p1%2Fr1%2F42", name="Pull Request"),
        rel("ArtifactLink", url="vstfs:///Git/Ref/p1%2Fr1%2FGBfeature%2Fgl-posting", name="Branch"),
        rel("ArtifactLink", url="vstfs:///Git/Commit/p1%2Fr1%2Fabcdef1234567890abcdef1234567890abcdef12", name="Fixed in Commit"),
    ], comments=5),
    2: wi(2, "Requirement", "Empty item"),
    5: wi(5, "Requirement", "Ünïcödé “quotes”, commas, and\nnewline", {"System.Description": "plain text, no tags"}, comments=1),
    7: wi(7, "Task", "Task item", {"System.Description": "- leading dash text"}),
    10: wi(10, "Epic", "Finance epic", {}, [rel("System.LinkTypes.Hierarchy-Forward", 1, name="Child")]),
    900: wi(900, "Feature", "Other project feature", project="Other"),
}
IN_PROJECT = [i for i, w in WORK_ITEMS.items() if w["fields"]["System.TeamProject"] == PROJECT]


def comment(cid, wid, who, text, date, rendered=None, deleted=False):
    c = {"workItemId": wid, "id": cid, "commentId": cid, "version": 1, "text": text, "createdBy": ident(who),
         "createdDate": date, "isDeleted": deleted, "format": "html"}
    if rendered is not None:
        c["renderedText"] = rendered
    return c


COMMENTS = {
    1: [  # deliberately out of order; one deleted; a markdown-format one with renderedText
        comment(13, 1, "Bob Smith", "Third <b>bold</b>", "2026-01-20T10:00:00Z"),
        comment(11, 1, "Ana López", "First comment &lt;tag&gt;", "2026-01-16T08:00:00Z"),
        comment(12, 1, "Chen Wei", "**md** second", "2026-01-18T12:00:00Z", rendered="<p><strong>md</strong> second</p>"),
        comment(14, 1, "Ghost", "deleted", "2026-01-21T10:00:00Z", deleted=True),
        comment(15, 1, "Ana López", "<div><a href=\"#\" data-vss-mention=\"version:2.0,x\">@Bob Smith</a> please review</div>", "2026-01-22T10:00:00Z"),
    ],
    5: [comment(51, 5, "Ana López", "only one", "2026-02-02T10:00:00Z")],
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body, headers=None):
        data = json.dumps(body).encode("utf-8") if not isinstance(body, (bytes, str)) else (body.encode("utf-8") if isinstance(body, str) else body)
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        expected = "Basic " + base64.b64encode(f":{PAT}".encode()).decode()
        return self.headers.get("Authorization") == expected

    def route(self, method):
        u = urlparse(self.path)
        path = unquote(u.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length).decode("utf-8")) if length else None
        CALLS.append({"method": method, "path": path, "query": q, "body": body})

        if path == "/__calls":
            return self.send(200, CALLS)
        if not self.authorized():
            return self.send(401, {"message": "TF400813: unauthorized"})
        if "api-version" not in q:
            return self.send(400, {"message": "api-version missing"})

        m = re.fullmatch(rf"/{ORG}/_apis/projects/(.+)", path)
        if m:
            if m.group(1).lower() != PROJECT.lower():
                return self.send(404, {"message": f"TF200016: project {m.group(1)} does not exist"})
            return self.send(200, {"id": "p1", "name": PROJECT})
        if path == f"/{ORG}/{PROJECT}/_apis/wit/fields":
            return self.send(200, {"count": len(FIELDS), "value": FIELDS})
        if path == f"/{ORG}/_apis/wit/workitemrelationtypes":
            return self.send(200, {"value": [
                {"referenceName": "System.LinkTypes.Related", "name": "Related"},
                {"referenceName": "System.LinkTypes.Hierarchy-Forward", "name": "Child"},
                {"referenceName": "System.LinkTypes.Hierarchy-Reverse", "name": "Parent"},
            ]})
        if path == f"/{ORG}/{PROJECT}/_apis/wit/wiql" and method == "POST":
            wiql = body["query"]
            if "@project" not in wiql:
                return self.send(400, {"message": "expected @project"})
            last = int(re.search(r"\[System\.Id\] > (\d+)", wiql).group(1))
            types = re.search(r"\[System\.WorkItemType\] IN \((.*?)\)", wiql)
            allowed = [t.strip().strip("'") for t in types.group(1).split(",")] if types else None
            top = int(q.get("$top", 20000))
            ids = sorted(i for i in IN_PROJECT if i > last and (allowed is None or WORK_ITEMS[i]["fields"]["System.WorkItemType"] in allowed))
            return self.send(200, {"queryType": "flat", "workItems": [{"id": i, "url": BASE + str(i)} for i in ids[:top]]})
        if path in (f"/{ORG}/{PROJECT}/_apis/wit/workitemsbatch", f"/{ORG}/_apis/wit/workitemsbatch") and method == "POST":
            ids = body.get("ids", [])
            if len(ids) > 200:
                return self.send(400, {"message": "max 200 ids"})
            if body.get("$expand") and body.get("fields"):
                return self.send(400, {"message": "The expand parameter can not be used with the fields parameter."})
            out = []
            for i in ids:
                w = WORK_ITEMS.get(i)
                if w is None:
                    out.append(None)
                    continue
                item = {"id": i, "rev": w["rev"], "url": w["url"]}
                if body.get("fields"):
                    item["fields"] = {k: v for k, v in w["fields"].items() if k in body["fields"]}
                else:
                    item["fields"] = dict(w["fields"])
                if (body.get("$expand") or "").lower() in ("relations", "all") and w["relations"]:
                    item["relations"] = w["relations"]
                out.append(item)
            return self.send(200, {"count": len(out), "value": out})
        m = re.fullmatch(rf"/{ORG}/{PROJECT}/_apis/wit/workItems/(\d+)/comments", path)
        if m:
            wid = int(m.group(1))
            if wid == 1 and INJECT["429"]:
                INJECT["429"] = False
                return self.send(429, {"message": "throttled"}, {"Retry-After": "1"})
            if wid == 5 and INJECT["503"]:
                INJECT["503"] = False
                return self.send(503, {"message": "unavailable"})
            items = [c for c in COMMENTS.get(wid, []) if not c["isDeleted"] or q.get("includeDeleted") == "true"]
            page = 2  # force paging
            start = int(q.get("continuationToken", "0") or 0)
            chunk = items[start:start + page]
            token = str(start + page) if start + page < len(items) else None
            res = {"totalCount": len(items), "count": len(chunk), "comments": chunk}
            if token:
                res["continuationToken"] = token
            return self.send(200, res)
        return self.send(404, {"message": f"no route {method} {path}"})

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")


if __name__ == "__main__":
    port = int(sys.argv[1])
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
