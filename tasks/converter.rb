# Based on convert script from vwall/compass-twitter-bootstrap gem.
# https://github.com/vwall/compass-twitter-bootstrap/blob/#{@branch}/build/convert.rb

require 'open-uri'
require 'json'
require 'fileutils'
require "pry"
require "dotenv"

require 'pathname'
require 'find'
require 'active_support/core_ext/string/inflections'
require 'active_support/ordered_hash'

Dotenv.load

class Converter

  GIT_DATA = 'https://api.github.com/repos'
  GIT_RAW  = 'https://raw.githubusercontent.com'
  TOKEN    = ENV['TOKEN']


  def initialize(branch)
    @repo               = 'Semantic-Org/Semantic-UI'
    @repo_url           = "https://github.com/#@repo"
    @branch             = branch || 'master'
    @git_data_trees     = "#{GIT_DATA}/#{@repo}/git/trees"
    @git_raw_src        = "#{GIT_RAW}/#{@repo}/#{@branch}/dist"
    @branch_sha         = get_tree_sha
  end

  def process
    # process_stylesheets_assets

    # process_images_and_fonts_assets
    # store_version

    checkout_repository
    choose_version(@branch)
    generate_variables
    process_stylesheets_assets
    process_javascript_assets
    store_version
  end

  def paths
    @gem_paths ||= Paths.new
  end

  def checkout_repository
    if Dir.exist?(paths.tmp_semantic_ui)
      system %Q{cd '#{paths.tmp_semantic_ui}' && git fetch --quiet}
    else
      system %Q{git clone --quiet git@github.com:Semantic-Org/Semantic-UI.git '#{paths.tmp_semantic_ui}'}
    end
  end

  def choose_version(version)
    system %Q{cd '#{paths.tmp_semantic_ui}' && git checkout --quiet #{version}}
  end
  
  # Generate a hash of variables from the theme and write them to a file
  def generate_variables
    @variables = ActiveSupport::OrderedHash.new
    # First, let's read all the site-wide variables
    parse_variable_file(File.join(paths.tmp_semantic_ui_theme, 'globals', 'site.variables'))
    
    # Now for each of the variable files, include their variables in a scope
    root = paths.tmp_semantic_ui_theme
    Find.find(root) do |path|
      if path.end_with? '.variables'
        scope = path.sub(%r{^#{Regexp.quote root}/}, '').sub(/\.variables$/,'')
        if scope != 'globals/site' # we've done this one
          parse_variable_file(path, scope)
        end
      end
    end

    variable_file_contents = ""
    @variables.each {|k,v| variable_file_contents += "#{k}: #{v} !default;\n"}
    save_file("variables", variable_file_contents, "", "")
  end

  def process_stylesheets_assets
    root = paths.tmp_semantic_ui_definitions
    Find.find(root) do |path|
      if path.end_with? '.less'
        scope, name = File.split(path.sub %r{^#{Regexp.quote root}/}, '')
        converted = convert(File.read(path), scope)
        name.sub! /\.less$/, ''
        save_file(name, converted, scope)
      end
    end
  end


  def process_javascript_assets
    # js = ""
    Dir[File.join(paths.tmp_semantic_ui_definitions, '**/*.js')].each do |src|
       name = File.basename(src).gsub(".js", '')
       # js << "//= require #{name}\n"
       FileUtils.cp(src, paths.javascripts)
     end
     # File.open("app/assets/javascripts/semantic-ui.js", "w+") { |file| file.write(js) }
  end


private

  # Get the sha of less branch
  def get_tree_sha
    sha = nil
    trees = get_json("#{@git_data_trees}/#{@branch}")
    trees['tree'].find{|t| t['path'] == 'dist'}['sha']
  end


  def convert(file, scope)
    file = remove_imports(file)
    file = replace_variables(file, scope)
    
    #file = replace_fonts_url(file)
    #file = replace_import_font_url(file)
    #file = replace_font_family(file)
    #file = replace_image_urls(file)
    #file = replace_image_paths(file)

    file
  end


  def save_file(name, content, path, prefix='_')

    name = name.gsub(/\.css/, '')
    file = "#{paths.stylesheets}/#{path}/#{prefix}#{name}.scss"
    dir = File.dirname(file)
    FileUtils.mkdir_p(dir) unless File.directory?(file)
    File.open(file, 'w+') { |f| f.write(content) }
    # puts "Saved #{name} at #{path}\n"
  end



  def get_json(url)
    url += "?access_token=#{TOKEN}" unless TOKEN.nil?
    data = open_git_file(url)
    data = JSON.parse data
  end

  def open_git_file(file)
    open(file).read
  end

  def store_version
    path = 'lib/semantic/ui/sass/version.rb'
    content = File.read(path).sub(/SEMANTIC_UI_SHA\s*=\s*['"][\w]+['"]/, "SEMANTIC_UI_SHA = '#@branch_sha'")
    File.open(path, 'w') { |f| f.write(content) }
  end
  
  # Remove LESS imports - we're going to let Asset Pipeline take care of that
  def remove_imports(less)
    less.gsub(/^\s*\@import.*$/, '').gsub(/.load(UIOverrides|Fonts)\(\);/, '')
  end
  
  # Replace LESS variables with Sass ones.
  def replace_variables(less, scope=nil)
    # Handle variables at the start of a string (Sass requires them to be #{})
    less.gsub!(/^\s*\@([-\w]+)(\s+[^\s:])/) { '#{' + get_sass_variable_name($1, scope) + '}' + $2 }
    # Handle most variable names
    less.gsub!(/\@([-\w]+)/) { get_sass_variable_name $1, scope }
    # And interpolated variables
    less.gsub!(/\@\{([-\w]+)\}/) { '#{' + get_sass_variable_name($1, scope) + '}' }
    less
  end

  def replace_fonts_url(less)
    less.gsub(/url\(\"\.\/\.\.\/themes\/default\/assets\/fonts\/?(.*?)\"\)/) {|s| "font-url(\"semantic-ui/#{$1}\")" }
  end

  def replace_font_family(less)
    less.gsub("font-family: 'Lato', 'Helvetica Neue', Arial, Helvetica, sans-serif", 'font-family: $font-family')
  end

  def replace_import_font_url(less)
    less.gsub("'https://fonts.googleapis.com/css?family=Lato:400,700,400italic,700italic&subset=latin'", '$font-url')
  end

  def replace_image_urls(less)
    less.gsub(/url\("?(.*?).png"?\)/) {|s| "image-url(\"#{$1}.png\")" }
  end

  def replace_image_paths(less)
    less.gsub('../themes/default/assets/images/', 'semantic-ui/')
  end
  
  def get_sass_variable_name(less_name, scope=nil, force=false)
    name = less_name.underscore.tr('_', '-')
    if scope
      name = "#{scope.tr '/', '-'}-#{name}"
    end
    name = "\$#{name}"
    
    unless force
      # If a scope is provided and we don't have a variable in that scope,
      # assume it's in the global scope
      if scope and !@variables.key? name
        return get_sass_variable_name(less_name, nil)
      end
    end
    return name
  end
  
  def parse_variable_file(filename, scope=nil)
    File.read(filename).scan(/^\s*\@([-\w]+)\s*:\s*(.*?);/) do |name, decl|
      name_parsed = get_sass_variable_name(name, scope, true)
      decl_parsed = replace_variables(decl, scope)
      @variables[name_parsed] = decl_parsed
    end
  end

end

class Paths
   attr_reader :root
   attr_reader :tmp
   attr_reader :tmp_semantic_ui
   attr_reader :tmp_semantic_ui_src
   attr_reader :tmp_semantic_ui_definitions
   attr_reader :tmp_semantic_ui_theme

   attr_reader :fonts
   attr_reader :images
   attr_reader :javascripts
   attr_reader :stylesheets


   def initialize
     @root = File.expand_path('..', __dir__)

     @tmp = File.join(@root, 'tmp')
     @tmp_semantic_ui = File.join(@tmp, 'semantic-ui')
     @tmp_semantic_ui_src = File.join(@tmp_semantic_ui, 'src')
     @tmp_semantic_ui_definitions = File.join(@tmp_semantic_ui_src, 'definitions')

     @tmp_semantic_ui_theme = File.join(@tmp_semantic_ui_src, 'themes', 'default')
    
     @app = File.join(@root, 'app')
     @fonts = File.join(@app, 'assets', 'fonts', 'semantic-ui')
     @images = File.join(@app, 'assets', 'images', 'semantic-ui')
     @javascripts = File.join(@app, 'assets', 'javascripts', 'semantic-ui')
     @stylesheets = File.join(@app, 'assets', 'stylesheets', 'semantic-ui')
   end
 end