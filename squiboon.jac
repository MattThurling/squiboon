node dialogue_root;

node dialogue_state {
  can bi_enc.infer;
  can tfm_ner.extract_entity;

  can classify_intent {
    intent_labels = -[intent_transition]->.edge.intent;
    visitor.wlk_ctx["intent"] = bi_enc.infer(
      contexts = [visitor.request],
      candidates = intent_labels,
      context_type = "text",
      candidate_type = "text"
    )[0]["predicted"]["label"];
  }

  
  can extract_entities {
    res = tfm_ner.extract_entity(visitor.request);
    for ent in res {
      ent_type = ent["entity_value"];
      ent_text = ent["entity_text"];
      if (!(ent_type in visitor.wlk_ctx["entities"])){
          visitor.wlk_ctx["entities"][ent_type] = [];
      }
      visitor.wlk_ctx["entities"][ent_type].l::append(ent_text);
    }
  }

  can init_wlk_ctx {
    new_wlk_ctx = {
      "intent": null,
      "entities": {},
      "prev_state": null,
      "next_state": null,
      "respond": false
    };
    if ("entities" in visitor.wlk_ctx) {
      // Carry over extracted entities from previous interaction
      new_wlk_ctx["entities"] = visitor.wlk_ctx["entities"];
    }
    visitor.wlk_ctx = new_wlk_ctx;
  }
  can nlu {}
  can process {
    if (visitor.wlk_ctx["prev_state"]): visitor.wlk_ctx["respond"] = true;
    else {
      visitor.wlk_ctx["next_state"] = net.root();
      visitor.wlk_ctx["prev_state"] = here;
    }
  }
  can nlg {}
}

node dialogue_root:dialogue_state {
  has name = "dialogue_root";
  can nlu {
    ::classify_intent;
  }
  can process {
      visitor.wlk_ctx["next_state"] = (-[intent_transition(intent==visitor.wlk_ctx["intent"])]->)[0];
  }
  can nlg {
      visitor.response = "Sorry I can't handle that just yet. Anything else I can help you with?";
  }
}

node register_state:dialogue_state {
  has hame = "register";
  can nlu {
    if (!visitor.wlk_ctx["intent"]): ::classify_intent;
    ::extract_entities;
  }
  can process {
    // Check entity transition
    required_entities = -[entity_transition]->.edge[0].context["entities"];
    if (vector.sort_by_key(visitor.wlk_ctx["entities"].d::keys) == vector.sort_by_key(required_entities)) {
        visitor.wlk_ctx["next_state"] = -[entity_transition]->[0];
        visitor.wlk_ctx["prev_state"] = here;
    } elif (visitor.wlk_ctx["prev_state"] and !visitor.wlk_ctx["prev_state"].context["name"] in ["register", "confirmation"]){
        next_state = -[intent_transition(intent==visitor.wlk_ctx["intent"])]->;
        if (next_state.length > 0 and visitor.wlk_ctx["intent"] != "no") {
            visitor.wlk_ctx["next_state"] = next_state[0];
            visitor.wlk_ctx["prev_state"] = here;
        } else {
            visitor.wlk_ctx["respond"] = true;
        }
    } else {
        visitor.wlk_ctx["respond"] = true;
    }
  }
  can nlg {
    if ("name" in visitor.wlk_ctx["entities"] and "age" not in visitor.wlk_ctx["entities"]):
      visitor.response = "What is your age?";
    elif ("age" in visitor.wlk_ctx["entities"] and "name" not in visitor.wlk_ctx["entities"]):
      visitor.response = "What is your name?";
    else:
      visitor.response = "I will need your name and age.";
  }
}

node confirmation:dialogue_state {
  has name = "confirmation";
  can nlu {
    if (!visitor.wlk_ctx["intent"]): ::classify_intent;
  }
  can process {
    if (visitor.wlk_ctx["prev_state"]): visitor.wlk_ctx["respond"] = true;
    else {
      visitor.wlk_ctx["next_state"] = -[intent_transition(intent==visitor.wlk_ctx["intent"])]->[0];
      visitor.wlk_ctx["prev_state"] = here;
    }
  }
  can nlg {
    visitor.response =
      "Can you confirm your name is " + visitor.wlk_ctx["entities"]["name"][0] + " and your age is " + visitor.wlk_ctx["entities"]["age"][0] + "?";
  }
}

node confirmed:dialogue_state {
  has name = "confirmed";
  can nlg {
    visitor.response = "Thanks, " + visitor.wlk_ctx["entities"]["name"][0] + ". That'll be all for now.";
  }
}

node canceled:dialogue_state {
  has name = "canceled";
  can nlg {
    visitor.response = "No worries. Some other time, maybe.";
  }
}

edge intent_transition {
  has intent;
}

edge entity_transition {
  has entities;
}

graph dialogue_system {
  has anchor dialogue_root;
  spawn {
    dialogue_root = spawn node::dialogue_root;
    register_state = spawn node::register_state;
    confirmation = spawn node::confirmation;
    confirmed = spawn node::confirmed;
    canceled = spawn node::canceled;

    dialogue_root -[intent_transition(intent="register")]-> register_state;
    register_state -[intent_transition(intent="cancel")]-> canceled;
    register_state -[entity_transition(entities=["name", "age"])]-> confirmation;
    register_state -[intent_transition(intent="provide name or age")]-> register_state;
    confirmation -[intent_transition(intent="yes")]-> confirmed;
    confirmation - [intent_transition(intent="no")]-> register_state;
    confirmation - [intent_transition(intent="cancel")]-> canceled;
  }
}

walker init {
  root {
    spawn here --> graph::dialogue_system;
    spawn here walker::talk;
  }
}

walker talk {
  has request, interactive = true; // have set this to true as a workaround
  has wlk_ctx = {
    "intent": null,
    "entities": {},
    "prev_state": null,
    "next_state": null,
    "respond": false
  };
  has response;
  root {
    take --> node::dialogue_root;
  }
  dialogue_state {
    if (!request and interactive) {
      request = std.input("(Ctrl-C to exit)> ");
      here::init_wlk_ctx;
    } elif (!request and !interactive) {
      std.err("ERROR: request is required for non-interactive mode");
      disengage;
    }
    here::nlu;
    here::process;
    if (visitor.wlk_ctx["respond"]) {
      here::nlg;
      if (interactive): std.out(response);
      else {
        yield report response;
        here::init_wlk_ctx;
      }
      request = null;
      take here;
    } else {
      take visitor.wlk_ctx["next_state"] else: take here;
    }
  }
}