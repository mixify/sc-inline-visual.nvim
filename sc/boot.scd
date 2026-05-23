// SC Inline Visual - SuperCollider helper
// Load this file to enable sending visual data to Neovim.
// Usage: ~visual.analysis("bass", amp, centroid);

~visual = (
  addr: NetAddr("127.0.0.1", 57121),

  analysis: { |target, amp=0, centroid=0|
    ~visual.addr.sendMsg("/sc/analysis", target.asString, amp, centroid);
  },

  event: { |target, name="event", amp=1|
    ~visual.addr.sendMsg("/sc/event", target.asString, name.asString, amp);
  },

  param: { |target, name, value|
    ~visual.addr.sendMsg("/sc/param", target.asString, name.asString, value);
  }
);
