// QML's V4 engine has no Intl. i18n.ts asks it for plural forms
// (Intl.PluralRules) and, outside English, for short month / weekday names
// (Intl.DateTimeFormat, UTC). This stands in for exactly those calls, for the
// 10 languages Coucou ships. Rules: CLDR (integers + simple decimals).
// Date tables generated from Electron's ICU (the reference Coucou's Intl).
// Anything else throws, which i18n.ts already catches (English fallback).
var Intl = (typeof Intl !== "undefined") ? Intl : (function () {
  function base(l) { l = String(l || "en"); return l === "zh-Hans" || l === "pt-BR" ? l : l.split("-")[0]; }
  function plural(lang, n) {
    var s = String(n), dot = s.indexOf("."), v = dot < 0 ? 0 : s.length - dot - 1;
    var i = Math.floor(Math.abs(n)), a = Math.abs(n);
    var mil = v === 0 && i !== 0 && i % 1000000 === 0;
    switch (base(lang)) {
      case "en": return i === 1 && v === 0 ? "one" : "other";
      case "zh-Hans": case "zh": case "id": return "other";
      case "hi": case "bn": return i === 0 || a === 1 ? "one" : "other";
      case "es": return a === 1 ? "one" : mil ? "many" : "other";
      case "fr": return i === 0 || i === 1 ? "one" : mil ? "many" : "other";
      case "pt-BR": case "pt": return i === 0 || i === 1 ? "one" : mil ? "many" : "other";
      case "ru":
        if (v !== 0) return "other";
        if (i % 10 === 1 && i % 100 !== 11) return "one";
        if (i % 10 >= 2 && i % 10 <= 4 && !(i % 100 >= 12 && i % 100 <= 14)) return "few";
        return "many";
      case "ar":
        if (a === 0) return "zero";
        if (a === 1) return "one";
        if (a === 2) return "two";
        if (v === 0 && i % 100 >= 3 && i % 100 <= 10) return "few";
        if (v === 0 && i % 100 >= 11 && i % 100 <= 99) return "many";
        return "other";
    }
    return a === 1 ? "one" : "other";
  }
  var T = {"zh-Hans":{"m":["1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"],"w":["周日","周一","周二","周三","周四","周五","周六"],"d":["1日","2日","3日","4日","5日","6日","7日","8日","9日","10日","11日","12日","13日","14日","15日","16日","17日","18日","19日","20日","21日","22日","23日","24日","25日","26日","27日","28日","29日","30日","31日"],"dm":["1月{d}","2月{d}","3月{d}","4月{d}","5月{d}","6月{d}","7月{d}","8月{d}","9月{d}","10月{d}","11月{d}","12月{d}"]},"hi":{"m":["जन॰","फ़र॰","मार्च","अप्रैल","मई","जून","जुल॰","अग॰","सित॰","अक्टू॰","नव॰","दिस॰"],"w":["रवि","सोम","मंगल","बुध","गुरु","शुक्र","शनि"],"d":["1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","30","31"],"dm":["{d} जन॰","{d} फ़र॰","{d} मार्च","{d} अप्रैल","{d} मई","{d} जून","{d} जुल॰","{d} अग॰","{d} सित॰","{d} अक्टू॰","{d} नव॰","{d} दिस॰"]},"es":{"m":["ene","feb","mar","abr","may","jun","jul","ago","sept","oct","nov","dic"],"w":["dom","lun","mar","mié","jue","vie","sáb"],"d":["1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","30","31"],"dm":["{d} ene","{d} feb","{d} mar","{d} abr","{d} may","{d} jun","{d} jul","{d} ago","{d} sept","{d} oct","{d} nov","{d} dic"]},"ar":{"m":["يناير","فبراير","مارس","أبريل","مايو","يونيو","يوليو","أغسطس","سبتمبر","أكتوبر","نوفمبر","ديسمبر"],"w":["الأحد","الاثنين","الثلاثاء","الأربعاء","الخميس","الجمعة","السبت"],"d":["1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","30","31"],"dm":["{d} يناير","{d} فبراير","{d} مارس","{d} أبريل","{d} مايو","{d} يونيو","{d} يوليو","{d} أغسطس","{d} سبتمبر","{d} أكتوبر","{d} نوفمبر","{d} ديسمبر"]},"fr":{"m":["janv.","févr.","mars","avr.","mai","juin","juil.","août","sept.","oct.","nov.","déc."],"w":["dim.","lun.","mar.","mer.","jeu.","ven.","sam."],"d":["1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","30","31"],"dm":["{d} janv.","{d} févr.","{d} mars","{d} avr.","{d} mai","{d} juin","{d} juil.","{d} août","{d} sept.","{d} oct.","{d} nov.","{d} déc."]},"bn":{"m":["জানু","ফেব","মার্চ","এপ্রিল","মে","জুন","জুলাই","আগস্ট","সেপ্টেম্বর","অক্টোবর","নভেম্বর","ডিসেম্বর"],"w":["রবি","সোম","মঙ্গল","বুধ","বৃহস্পতি","শুক্র","শনি"],"d":["১","২","৩","৪","৫","৬","৭","৮","৯","১০","১১","১২","১৩","১৪","১৫","১৬","১৭","১৮","১৯","২০","২১","২২","২৩","২৪","২৫","২৬","২৭","২৮","২৯","৩০","৩১"],"dm":["{d} জানু","{d} ফেব","{d} মার্চ","{d} এপ্রি","{d} মে","{d} জুন","{d} জুল","{d} আগ","{d} সেপ","{d} অক্টো","{d} নভে","{d} ডিসে"]},"pt-BR":{"m":["jan.","fev.","mar.","abr.","mai.","jun.","jul.","ago.","set.","out.","nov.","dez."],"w":["dom.","seg.","ter.","qua.","qui.","sex.","sáb."],"d":["1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","30","31"],"dm":["{d} de jan.","{d} de fev.","{d} de mar.","{d} de abr.","{d} de mai.","{d} de jun.","{d} de jul.","{d} de ago.","{d} de set.","{d} de out.","{d} de nov.","{d} de dez."]},"ru":{"m":["янв.","февр.","март","апр.","май","июнь","июль","авг.","сент.","окт.","нояб.","дек."],"w":["вс","пн","вт","ср","чт","пт","сб"],"d":["1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","30","31"],"dm":["{d} янв.","{d} февр.","{d} мар.","{d} апр.","{d} мая","{d} июн.","{d} июл.","{d} авг.","{d} сент.","{d} окт.","{d} нояб.","{d} дек."]},"id":{"m":["Jan","Feb","Mar","Apr","Mei","Jun","Jul","Agu","Sep","Okt","Nov","Des"],"w":["Min","Sen","Sel","Rab","Kam","Jum","Sab"],"d":["1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","30","31"],"dm":["{d} Jan","{d} Feb","{d} Mar","{d} Apr","{d} Mei","{d} Jun","{d} Jul","{d} Agu","{d} Sep","{d} Okt","{d} Nov","{d} Des"]}};
  function PluralRules(lang) { this.lang = lang; }
  PluralRules.prototype.select = function (n) { return plural(this.lang, Number(n)); };
  function DateTimeFormat(lang, opts) {
    var t = T[String(lang)];
    if (!t) throw new RangeError("Intl shim: no date table for " + lang);
    this.t = t; this.o = opts || {};
  }
  DateTimeFormat.prototype.format = function (date) {
    var o = this.o, t = this.t, keys = Object.keys(o).filter(function (k) { return k !== "timeZone"; }).sort().join(",");
    if (o.timeZone && o.timeZone !== "UTC") throw new RangeError("Intl shim: UTC only");
    var m = date.getUTCMonth(), d = date.getUTCDate();
    if (keys === "month" && o.month === "short") return t.m[m];
    if (keys === "weekday" && o.weekday === "short") return t.w[date.getUTCDay()];
    if (keys === "day" && o.day === "numeric") return t.d[d - 1];
    if (keys === "day,month" && o.month === "short" && o.day === "numeric") return t.dm[m].replace("{d}", t.d[d - 1]);
    throw new RangeError("Intl shim: unsupported options " + keys);
  };
  return { PluralRules: PluralRules, DateTimeFormat: DateTimeFormat, __shim: true };
})();
