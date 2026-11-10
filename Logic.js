.pragma library

var MAX_NAME = 48

function isIPv4(s) {
  if (typeof s !== "string") return false
  var m = s.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)
  if (!m) return false
  for (var i = 1; i <= 4; i++) if (Number(m[i]) > 255) return false
  return true
}

function ipToInt(ip) {
  if (!isIPv4(ip)) return -1
  var p = ip.split(".")
  return ((Number(p[0]) * 256 + Number(p[1])) * 256 + Number(p[2])) * 256 + Number(p[3])
}

function intToIp(n) {
  return [Math.floor(n / 16777216) % 256, Math.floor(n / 65536) % 256, Math.floor(n / 256) % 256, n % 256].join(".")
}

function isMac(s) {
  return typeof s === "string" && /^[0-9A-F]{2}(:[0-9A-F]{2}){5}$/.test(s)
}

function cleanText(s, max) {
  if (s === null || s === undefined) return ""
  var t = String(s).replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").trim()
  return t.length > max ? t.substring(0, max) : t
}

function cleanName(s) {
  return cleanText(s, MAX_NAME)
}

// config comes from a user file, so everything gets checked before use
function parseConfig(text) {
  var raw
  try { raw = JSON.parse(text) } catch (e) { return { error: "config.json is not valid JSON" } }
  if (!raw || typeof raw !== "object") return { error: "config.json must be an object" }
  var router = String(raw.router || "")
  if (!/^https?:\/\/[A-Za-z0-9.\-:\[\]]+$/.test(router)) return { error: "router must look like http://192.168.88.1" }
  var lanes = []
  var list = Array.isArray(raw.lanes) ? raw.lanes : []
  for (var i = 0; i < list.length && i < 8; i++) {
    var l = list[i] || {}
    var from = ipToInt(String(l.from || "")), to = ipToInt(String(l.to || ""))
    var id = cleanText(l.id, 24)
    if (!id || from < 0 || to < from || to - from > 4096) return { error: "lane " + (i + 1) + " needs id, from and to (from <= to)" }
    lanes.push({ id: id, name: cleanText(l.name || id, 32), from: from, to: to, fromIp: intToIp(from), toIp: intToIp(to), pool: l.pool === true })
  }
  if (lanes.length === 0) return { error: "config.json needs at least one lane" }
  var notes = {}
  if (raw.notes && typeof raw.notes === "object") {
    for (var mac in raw.notes) {
      var m = String(mac).toUpperCase()
      if (isMac(m)) notes[m] = cleanText(raw.notes[mac], 80)
    }
  }
  var aps = []
  var apList = Array.isArray(raw.aps) ? raw.aps : []
  for (var a = 0; a < apList.length && a < 8; a++) {
    var ap = apList[a] || {}
    var url = String(ap.url || "")
    if (!/^https?:\/\/[A-Za-z0-9.\-:\[\]]+$/.test(url)) return { error: "aps[" + a + "].url must look like http://192.168.88.2" }
    aps.push({ name: cleanText(ap.name || url, 32), url: url.replace(/\/+$/, "") })
  }
  var away = Number(raw.awayMinutes)
  var poll = Number(raw.pollSeconds)
  return {
    vpnLabel: cleanText(raw.vpnLabel || "the VPN", 32),
    aps: aps,
    awayMinutes: away >= 1 && away <= 240 ? away : 10,
    router: router.replace(/\/+$/, ""),
    dhcpServer: cleanText(raw.dhcpServer || "", 32),
    pollSeconds: poll >= 3 && poll <= 600 ? poll : 10,
    kickWifi: raw.kickWifi !== false,
    notify: raw.notify !== false,
    lanes: lanes,
    notes: notes
  }
}

function laneFor(ip, lanes) {
  var n = ipToInt(ip)
  if (n < 0) return ""
  for (var i = 0; i < lanes.length; i++) if (n >= lanes[i].from && n <= lanes[i].to) return lanes[i].id
  return ""
}

function laneById(id, lanes) {
  for (var i = 0; i < lanes.length; i++) if (lanes[i].id === id) return lanes[i]
  return null
}

function bandLabel(band) {
  var b = String(band || "")
  if (b.indexOf("2ghz") === 0) return "2.4 GHz"
  if (b.indexOf("5ghz") === 0) return "5 GHz"
  if (b.indexOf("6ghz") === 0) return "6 GHz"
  return ""
}

// cap looks like "ap2@AA:BB:CC:DD:EE:FF%*9"
function apName(radioName, radios, identity) {
  var r = radios[radioName]
  if (r && r.cap) return cleanText(String(r.cap).split("@")[0], 32)
  if (r && r.master) return apName(r.master, radios, identity)
  return identity
}

function buildDevices(input, cfg) {
  var leases = Array.isArray(input.leases) ? input.leases.slice(0, 1024) : []
  var regs = Array.isArray(input.regs) ? input.regs.slice(0, 1024) : []
  var arps = Array.isArray(input.arps) ? input.arps.slice(0, 2048) : []
  var radioList = Array.isArray(input.radios) ? input.radios.slice(0, 64) : []
  var identity = cleanText(input.identity || "router", 32)

  var radios = {}
  for (var r = 0; r < radioList.length; r++) {
    var rd = radioList[r] || {}
    radios[String(rd.name)] = { cap: rd.cap || "", master: rd["master-interface"] || "", ssid: cleanText(rd["configuration.ssid"], 32) }
  }
  var wifiByMac = {}
  for (var w = 0; w < regs.length; w++) {
    var g = regs[w] || {}
    var gm = String(g["mac-address"] || "").toUpperCase()
    if (!isMac(gm)) continue
    var iface = String(g.interface || "")
    wifiByMac[gm] = {
      regId: String(g[".id"] || ""),
      ap: apName(iface, radios, identity),
      band: bandLabel(g.band),
      ssid: cleanText(g.ssid || (radios[iface] ? radios[iface].ssid : ""), 32),
      signal: Number(g.signal) || 0
    }
  }
  var arpByMac = {}
  for (var a = 0; a < arps.length; a++) {
    var p = arps[a] || {}
    var pm = String(p["mac-address"] || "").toUpperCase()
    if (isMac(pm)) arpByMac[pm] = String(p.status || "")
  }

  var out = []
  for (var i = 0; i < leases.length; i++) {
    var l = leases[i] || {}
    if (cfg.dhcpServer && l.server && l.server !== cfg.dhcpServer) continue
    var mac = String(l["mac-address"] || "").toUpperCase()
    if (!isMac(mac) || !isIPv4(String(l.address || ""))) continue
    var isStatic = String(l.dynamic) !== "true"
    var status = String(l.status || "")
    var activeIp = isIPv4(String(l["active-address"] || "")) ? String(l["active-address"]) : ""
    var wifi = wifiByMac[mac] || null
    var arp = arpByMac[mac] || ""
    var hostName = cleanText(l["host-name"], MAX_NAME)
    var comment = cleanName(l.comment)
    var online = !!wifi || arp === "reachable" || arp === "delay" || arp === "probe"
    out.push({
      key: mac,
      mac: mac,
      leaseId: String(l[".id"] || ""),
      ip: String(l.address),
      activeIp: activeIp,
      name: comment || hostName || mac,
      named: comment !== "",
      hostName: hostName,
      isStatic: isStatic,
      status: status,
      lastSeen: cleanText(l["last-seen"], 24),
      online: online,
      bound: status === "bound",
      pending: isStatic && status === "bound" && activeIp !== "" && activeIp !== String(l.address),
      wifi: wifi,
      wired: !wifi && status === "bound",
      vpn: String(l["address-lists"] || "").split(",").indexOf("omarchy-vpn-us") !== -1,
      classId: cleanText(l["class-id"], 40),
      randomMac: isRandomMac(mac),
      addressLists: cleanText(l["address-lists"], 200),
      lane: laneFor(String(l.address), cfg.lanes),
      note: cfg.notes[mac] || ""
    })
  }
  out.sort(function(x, y) { return ipToInt(x.ip) - ipToInt(y.ip) })
  return out
}

function usedAddresses(devices, cfg) {
  var used = {}
  for (var i = 0; i < devices.length; i++) {
    used[devices[i].ip] = true
    if (devices[i].activeIp) used[devices[i].activeIp] = true
  }
  var host = cfg.router.replace(/^https?:\/\//, "").split(":")[0]
  if (isIPv4(host)) used[host] = true
  return used
}

function nextFreeIp(laneId, devices, cfg, keepMac) {
  var lane = laneById(laneId, cfg.lanes)
  if (!lane) return ""
  var used = usedAddresses(devices.filter(function(d) { return d.mac !== keepMac }), cfg)
  for (var n = lane.from; n <= lane.to; n++) {
    var ip = intToIp(n)
    if (!used[ip] && n % 256 !== 0 && n % 256 !== 255) return ip
  }
  return ""
}

function validateAssign(ip, laneId, mac, devices, cfg) {
  if (!isIPv4(ip)) return "That isn't an IPv4 address"
  var lane = laneById(laneId, cfg.lanes)
  if (!lane) return "Unknown lane"
  var n = ipToInt(ip)
  if (n < lane.from || n > lane.to) return "Outside " + lane.name + " (" + lane.fromIp + " – " + lane.toIp + ")"
  var used = usedAddresses(devices.filter(function(d) { return d.mac !== mac }), cfg)
  if (used[ip]) return ip + " is already taken"
  return ""
}

function laneCounts(devices, lanes) {
  var c = {}
  for (var i = 0; i < lanes.length; i++) c[lanes[i].id] = 0
  for (var j = 0; j < devices.length; j++) if (c[devices[j].lane] !== undefined) c[devices[j].lane]++
  return c
}

function unsorted(devices) {
  return devices.filter(function(d) { return !d.isStatic })
}

function signalBars(dbm) {
  if (!dbm) return 0
  if (dbm >= -55) return 4
  if (dbm >= -65) return 3
  if (dbm >= -75) return 2
  return 1
}

// kid-control rates look like "352bps", "1.2kbps", "15.3Mbps"
function parseRate(s) {
  var m = String(s || "").match(/^([\d.]+)\s*([kMG]?)bps$/)
  if (!m) return 0
  var mult = { "": 1, k: 1e3, M: 1e6, G: 1e9 }[m[2]]
  return Math.round(Number(m[1]) * mult)
}

function formatRate(bps) {
  if (!bps || bps < 1000) return (bps || 0) + " b/s"
  if (bps < 1e6) return (bps / 1e3).toFixed(bps < 1e4 ? 1 : 0) + " kb/s"
  if (bps < 1e9) return (bps / 1e6).toFixed(bps < 1e7 ? 1 : 0) + " Mb/s"
  return (bps / 1e9).toFixed(1) + " Gb/s"
}

function kidName(mac) {
  return "o-" + String(mac).replace(/:/g, "").toLowerCase()
}

function isHHMM(s) {
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(String(s || ""))
}

function hhmmToRos(s) {
  var p = String(s).split(":")
  var h = Number(p[0]), m = Number(p[1])
  return (h ? h + "h" : "") + (m ? m + "m" : "") || "0s"
}

function rosToHHMM(s) {
  var m = String(s || "").match(/^(?:(\d+)h)?(?:(\d+)m)?(?:\d+s)?$/)
  if (!m) return ""
  var h = Number(m[1] || 0), mm = Number(m[2] || 0)
  return (h < 10 ? "0" : "") + h + ":" + (mm < 10 ? "0" : "") + mm
}

// bedtime 22:00 -> 07:00 means internet is allowed 07:00-22:00 every day
function bedtimeWindow(from, to) {
  if (!isHHMM(from) || !isHHMM(to)) return { error: "Use HH:MM" }
  if (from === to) return { error: "Start and end can't be the same" }
  if (from < to) return { error: "Bedtime has to cross midnight (e.g. 22:00 → 07:00)" }
  return { window: hhmmToRos(to) + "-" + hhmmToRos(from) }
}

function windowToBedtime(win) {
  var m = String(win || "").match(/^([0-9hms]+)-([0-9hms]+)$/)
  if (!m || win === "0s-1d") return null
  var to = rosToHHMM(m[1]), from = rosToHHMM(m[2])
  if (!to || !from) return null
  return { from: from, to: to }
}

// router logs "--- got query from 192.168.88.31:1234:" then "question: name.:A:IN"; reply questions repeat without a query line
function parseLookups(rows, ip, limit) {
  var out = [], seenNames = {}, pending = ""
  var list = Array.isArray(rows) ? rows : []
  var pairs = []
  for (var j = 0; j < list.length; j++) {
    var msg = String((list[j] && list[j].message) || "")
    var q = msg.match(/^--- got query from (\d+\.\d+\.\d+\.\d+):\d+:$/)
    if (q) { pending = q[1]; continue }
    var a = msg.match(/^question: (.+?)\.?:([A-Z0-9 ()]+):IN$/)
    if (a && pending) {
      pairs.push({ ip: pending, name: a[1], time: String((list[j] && list[j].time) || "") })
      pending = ""
    }
  }
  for (var k = pairs.length - 1; k >= 0 && out.length < limit; k--) {
    var p = pairs[k]
    if (p.ip !== ip || seenNames[p.name]) continue
    seenNames[p.name] = true
    out.push({ name: cleanText(p.name, 120), time: cleanText(p.time.split(" ").pop(), 10) })
  }
  return out
}

// away only after being gone for awayMs, so a phone napping its wifi doesn't count as leaving
function presenceStep(state, presentNow, now, awayMs) {
  var s = state || { home: presentNow, lastSeen: presentNow ? now : 0 }
  var event = ""
  if (presentNow) {
    if (!s.home) event = "arrived"
    s = { home: true, lastSeen: now }
  } else if (s.home && now - s.lastSeen >= awayMs) {
    event = "left"
    s = { home: false, lastSeen: s.lastSeen }
  }
  return { state: s, event: event }
}

function attachKids(devices, kids, kidDevs) {
  var kidByName = {}
  var kl = Array.isArray(kids) ? kids : []
  for (var i = 0; i < kl.length; i++) if (kl[i] && kl[i].name) kidByName[String(kl[i].name)] = kl[i]
  var devByMac = {}
  var dl = Array.isArray(kidDevs) ? kidDevs : []
  for (var j = 0; j < dl.length; j++) {
    var m = String((dl[j] && dl[j]["mac-address"]) || "").toUpperCase()
    if (isMac(m)) devByMac[m] = dl[j]
  }
  for (var k = 0; k < devices.length; k++) {
    var d = devices[k]
    var kd = devByMac[d.mac] || null
    var kid = kd ? kidByName[String(kd.user || "")] : null
    var own = !!kid && kid.name === kidName(d.mac)
    d.kidDeviceId = kd ? String(kd[".id"] || "") : ""
    d.kidId = own ? String(kid[".id"] || "") : ""
    d.paused = !!kid && String(kid.paused) === "true"
    d.bedtime = own && kid.mon === kid.tue && kid.mon === kid.wed && kid.mon === kid.thu && kid.mon === kid.fri && kid.mon === kid.sat && kid.mon === kid.sun ? windowToBedtime(kid.mon) : null
    d.rateDown = kd ? parseRate(kd["rate-down"]) : 0
    d.rateUp = kd ? parseRate(kd["rate-up"]) : 0
  }
  return devices
}

// second hex digit 2, 6, A or E = locally administered, phones use these as private wifi addresses
function isRandomMac(mac) {
  return isMac(mac) && "26AE".indexOf(mac.charAt(1)) !== -1
}

var KNOWN_MODELS = {
  "M2101K6G": "Xiaomi Redmi Note 10 Pro",
  "M2101K6R": "Xiaomi Redmi Note 10 Pro",
  "M2007J20CG": "Xiaomi POCO X3 NFC",
  "M2102J20SG": "Xiaomi POCO X3 Pro",
  "C200": "TP-Link Tapo C200 camera",
  "C210": "TP-Link Tapo C210 camera"
}

var HOST_RULES = [
  [/^M\d{4}[A-Z0-9]{2,6}$/, "Xiaomi / Redmi / POCO phone"],
  [/^(SM-[A-Z]\d+|Galaxy)/i, "Samsung Galaxy"],
  [/iPhone/i, "iPhone"],
  [/iPad/i, "iPad"],
  [/MacBook|iMac|Mac-?mini|-Mac$/i, "Mac"],
  [/Apple-?TV/i, "Apple TV"],
  [/^(DESKTOP|LAPTOP)-/i, "Windows PC"],
  [/^android[-_]/i, "Android device"],
  [/Pixel/i, "Google Pixel"],
  [/Nest|Chromecast|Google-?Home/i, "Google Nest / Chromecast"],
  [/^(ESP[_-]|tasmota|shelly)/i, "ESP-based smart device"],
  [/^Ring/i, "Ring device"],
  [/Tesla/i, "Tesla"],
  [/Nintendo|Switch/i, "Nintendo Switch"],
  [/PS[45]|PlayStation/i, "PlayStation"],
  [/XBOX/i, "Xbox"],
  [/Meross/i, "Meross smart device"],
  [/kindle|echo|fire-?tv|amazon/i, "Amazon device"],
  [/HUAWEI|HONOR/i, "Huawei / Honor phone"],
  [/OPPO|realme|OnePlus|vivo/i, "Oppo / OnePlus / vivo phone"],
  [/^wlan0$/, "Linux gadget (often Tuya smart plugs/bulbs)"]
]

var CLASS_RULES = [
  [/^android-dhcp-(\d+)/, function(m) { return "Android " + m[1] }],
  [/^MSFT 5\.0/, function() { return "Windows-style DHCP (PC or camera)" }],
  [/^udhcp/, function() { return "embedded Linux" }],
  [/^dhcpcd/, function() { return "Linux / older Android" }]
]

function guessDevice(d, vendor) {
  var parts = [], why = []
  var host = String(d.hostName || "")
  var model = KNOWN_MODELS[host.toUpperCase()]
  if (model) { parts.push(model); why.push("model code " + host) }
  else {
    for (var i = 0; i < HOST_RULES.length; i++) if (HOST_RULES[i][0].test(host)) { parts.push(HOST_RULES[i][1]); why.push("name " + host); break }
  }
  for (var j = 0; j < CLASS_RULES.length; j++) {
    var m = String(d.classId || "").match(CLASS_RULES[j][0])
    if (m) { parts.push(CLASS_RULES[j][1](m)); why.push("DHCP " + d.classId); break }
  }
  if (vendor) { parts.push("made by " + vendor); why.push("MAC vendor") }
  else if (d.randomMac) { parts.push("private WiFi address (phone, tablet or laptop)"); why.push("randomized MAC") }
  return { label: parts.join(" · "), why: why.join(", ") }
}

var DOMAIN_HINTS = [
  [/xiaomi|miui|mi\.com|mi-img/, "Xiaomi"], [/apple|icloud|mzstatic/, "Apple"], [/samsung/, "Samsung"],
  [/amazon|a2z|alexa/, "Amazon"], [/tuya|tuyaeu/, "Tuya"], [/ring\.com|ring\.amazon/, "Ring"],
  [/nintendo/, "Nintendo"], [/playstation|sony/, "Sony"], [/huawei|hicloud/, "Huawei"], [/meross/, "Meross"],
  [/govee/, "Govee"], [/philips-hue|meethue/, "Philips Hue"], [/tplinkcloud|tapo/, "TP-Link"], [/hisense|connectlife/, "Hisense"],
  [/roku/, "Roku"], [/tesla/, "Tesla"], [/microsoft|windowsupdate|msftconnecttest/, "Windows"], [/android|googleapis\.com\/android|play\.googleapis/, "Android"]
]

function guessFromLookups(list) {
  var score = {}
  var l = Array.isArray(list) ? list : []
  for (var i = 0; i < l.length; i++) {
    for (var j = 0; j < DOMAIN_HINTS.length; j++) if (DOMAIN_HINTS[j][0].test(String(l[i].name))) score[DOMAIN_HINTS[j][1]] = (score[DOMAIN_HINTS[j][1]] || 0) + 1
  }
  var best = Object.keys(score).sort(function(a, b) { return score[b] - score[a] })
  return best.length ? best.slice(0, 2).join(" / ") : ""
}
