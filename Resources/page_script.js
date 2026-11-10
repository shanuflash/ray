(function (post) {
  "use strict";
  if (!/^(https?|file):$/.test(location.protocol)) return () => {};
  const handlers = Object.create(null);
  const { stringify: toJSON, parse: fromJSON } = JSON;
  const apply = Reflect.apply;
  const receive = (kind, json) => {
    const handler = handlers[kind];
    if (!handler) return;
    try {
      handler(fromJSON(json));
    } catch (e) {}
  };
  // Screen sharing goes to Ray's own picker, from any frame the page lets share (docs/mocks/screen-share.html).
  installDisplayMedia();
  if (window !== window.top) return receive;
  return main();

  function main() {
    post("hello", "{}");
    return receive;
  }

  // getDisplayMedia() asks Ray (`displayMedia`); Ray's answer is the source the person chose, which this frame then
  // opens with getUserMedia: the engine allows that one source, for this frame and origin, for 15 s. The engine drops
  // the message without the permissions policy or a click, so those are refused here first, as Chrome does.
  function installDisplayMedia() {
    const devices = navigator.mediaDevices;
    const proto = devices && Object.getPrototypeOf(devices);
    if (!proto || typeof proto.getDisplayMedia !== "function" || typeof proto.getUserMedia !== "function") return;
    const getUserMedia = proto.getUserMedia;
    const activation = navigator.userActivation;
    const isActive = activation && Object.getOwnPropertyDescriptor(Object.getPrototypeOf(activation), "isActive");
    const policy = document.featurePolicy;
    const allowsFeature = policy && policy.allowsFeature;
    const Exception = DOMException;
    const PromiseType = Promise;
    const then = Promise.prototype.then;
    const min = Math.min;
    // Plain objects and captured functions: the page can replace Map, Array and Promise methods after this runs.
    const requests = Object.create(null);
    let sequence = 0;
    const getDisplayMedia = {
      getDisplayMedia(constraints) {
        const refuse = (message, name) => new PromiseType((_, reject) => reject(new Exception(message, name)));
        if (policy && allowsFeature && !apply(allowsFeature, policy, ["display-capture"]))
          return refuse('Access to the feature "display-capture" is disallowed by permissions policy.', "NotAllowedError");
        if (isActive && !apply(isActive.get, activation, []))
          return refuse("getDisplayMedia() requires transient activation (user gesture).", "InvalidStateError");
        const self = this;
        const options = constraints && typeof constraints === "object" ? constraints : {};
        const video = options.video && typeof options.video === "object" ? options.video : {};
        return new PromiseType((resolve, reject) => {
          const id = ++sequence;
          requests[id] = { self, resolve, reject, video };
          const pick = (value, a, b, c) => (value === a || value === b || value === c ? value : "");
          post("displayMedia", toJSON({
            id,
            audio: !!options.audio,
            systemAudio: options.systemAudio !== "exclude",
            windowAudio: pick(options.windowAudio, "exclude", "window", "system") || "system",
            surface: pick(video.displaySurface, "browser", "window", "monitor"),
            selfTab: options.selfBrowserSurface !== "exclude",
          }));
        });
      },
    }.getDisplayMedia;
    proto.getDisplayMedia = getDisplayMedia;
    handlers.displayMedia = (answer) => {
      const request = answer && typeof answer.id === "number" ? requests[answer.id] : undefined;
      if (!request) return;
      delete requests[answer.id];
      if (typeof answer.sourceId !== "string" || !answer.sourceId) {
        request.reject(new Exception("Permission denied", "NotAllowedError"));
        return;
      }
      const rate = request.video.frameRate;
      const frameRate = +(rate && typeof rate === "object" ? rate.max || rate.ideal : rate) || 30;
      apply(then, apply(getUserMedia, request.self, [{
        audio: answer.audio === true ? { mandatory: { chromeMediaSource: "desktop" } } : false,
        video: { mandatory: { chromeMediaSource: "desktop", chromeMediaSourceId: answer.sourceId, maxWidth: 3840,
          maxHeight: 2160, maxFrameRate: min(frameRate, 60) } },
      }]), [request.resolve, request.reject]);
    };
  }
})
