# check-overlaps.ps1 - detect text/element overlaps in a hero SVG
# Usage: .\tools\check-overlaps.ps1 -SvgPath .\vvibe-agent-tracker\hero-light.svg
#
# Renders the SVG in headless Edge, measures every solid element's real
# bounding box (getBoundingClientRect = true font metrics, not estimates),
# and reports intersections across different top-level branches plus any
# text-on-text collisions. Exit code 1 when overlaps are found.
#
# Known limits:
# - Elements inside class="spin" orbits and the radial glow are skipped
#   (they overlap things by design).
# - All CSS animations are frozen before measuring, so every element is
#   checked at its resting position (entrance offsets do not distort boxes).
# - Groups that overlap by design (stacked mascot layers, fanned cards)
#   should share one parent <g>; same-branch shape pairs are not flagged.

param(
  [Parameter(Mandatory = $true)][string]$SvgPath,
  [double]$MinArea = 10
)

$svgFull = (Resolve-Path $SvgPath).Path
$svg = [IO.File]::ReadAllText($svgFull)

$checker = @'
<script>
(function () {
  const svg = document.querySelector("svg");
  const skip = (el) =>
    el.closest(".spin,.spin-r") ||
    el.id.endsWith("bg") ||
    (el.getAttribute("fill") || "").startsWith("url(");
  const tops = [...svg.children].filter(
    (e) => !["defs", "style", "title", "desc"].includes(e.tagName)
  );
  const items = [];
  tops.forEach((top, branch) => {
    const els = top.matches("text,rect,circle,image")
      ? [top]
      : [...top.querySelectorAll("text,rect,circle,image")];
    els.forEach((el) => {
      if (skip(el)) return;
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return;
      items.push({
        branch,
        tag: el.tagName,
        label: (el.textContent || el.getAttribute("class") || el.tagName).trim().slice(0, 28),
        x: r.x, y: r.y, w: r.width, h: r.height,
        parent: el.parentElement,
      });
    });
  });
  const overlapArea = (a, b) => {
    const w = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
    const h = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
    return w > 0 && h > 0 ? w * h : 0;
  };
  const problems = [];
  for (let i = 0; i < items.length; i++) {
    for (let j = i + 1; j < items.length; j++) {
      const a = items[i], b = items[j];
      const bothText = a.tag === "text" && b.tag === "text";
      // same-branch layouts (icon on its own card, etc.) are by design;
      // only text-on-text is always wrong regardless of branch
      if (a.branch === b.branch && !(bothText && a.parent !== b.parent)) continue;
      const area = overlapArea(a, b);
      if (area >= __MIN_AREA__) {
        problems.push(
          `${a.tag}"${a.label}" x ${b.tag}"${b.label}" overlap ${Math.round(area)}px2` +
          ` at (${Math.round(Math.max(a.x, b.x))},${Math.round(Math.max(a.y, b.y))})`
        );
      }
    }
  }
  const pre = document.createElement("pre");
  pre.id = "ovl-report";
  pre.textContent = JSON.stringify({ checked: items.length, problems }, null, 1);
  document.body.appendChild(pre);
})();
</script>
'@

$checker = $checker.Replace('__MIN_AREA__', [string]$MinArea)
# fix body width to the viewBox width so reported coords match SVG coords 1:1
$vbw = 880
$m0 = [regex]::Match($svg, 'viewBox="0 0 (\d+)')
if ($m0.Success) { $vbw = [int]$m0.Groups[1].Value }
$freeze = "<style>* { animation: none !important } body { margin:0; width:${vbw}px }</style>"
$html = "<!doctype html><html><body>" + $freeze + $svg + $checker + "</body></html>"
$tmp = Join-Path $env:TEMP ("ovl-" + [IO.Path]::GetFileNameWithoutExtension($svgFull) + ".html")
[IO.File]::WriteAllText($tmp, $html, (New-Object System.Text.UTF8Encoding($false)))

$edge = @(
  "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
  "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Error "Edge not found"; exit 2 }

$dom = & $edge --headless=new --disable-gpu --dump-dom ("file:///" + $tmp.Replace('\','/')) 2>$null | Out-String
$m = [regex]::Match($dom, '(?s)<pre id="ovl-report">(.*?)</pre>')
if (-not $m.Success) { Write-Error "checker produced no report (DOM dump failed?)"; exit 2 }

$report = $m.Groups[1].Value -replace '&quot;','"' -replace '&amp;','&' -replace '&lt;','<' -replace '&gt;','>'
$data = $report | ConvertFrom-Json
Write-Output ("elements checked: " + $data.checked)
if ($data.problems.Count -eq 0) {
  Write-Output "OK - no overlaps found"
  exit 0
} else {
  Write-Output ("OVERLAPS FOUND: " + $data.problems.Count)
  $data.problems | ForEach-Object { Write-Output ("  - " + $_) }
  exit 1
}
