class Module extends require "views.base"
  content: =>
    h2 class: "list-header", ->
      text @module\get_name()
      text " (" .. @module\get_version() .. ")"
    @render_errors()
    div class: "cell", ->
      @render_endorse_button(@module)
      p class: "module-description", @module\get_description()
      url = @module\get_url()
      p a href: url, url
      @render_endorsers_and_labels(@module)
      @render_all_dependencies(@module)
      if @current_user and (@current_user\get_trust_level() > 1)
        form method: "POST", action: @url_for("main.module", id: @module.id), ->
          input type: "text", name: "label"
          input type: "submit", value: "add label"
          input type: "hidden", name: "action", value: "label"
