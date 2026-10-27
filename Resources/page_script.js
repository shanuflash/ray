(function (post) {
  "use strict";
  if (window !== window.top || !/^(https?|file):$/.test(location.protocol)) return () => {};
  return main();

  function main() {
    post("hello", "{}");
    return () => {};
  }
})
