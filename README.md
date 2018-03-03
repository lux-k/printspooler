# printspooler
Basic print spooler daemon for label printing

takes data files, transforms them in to a format appropriate for printing to
a label printer and then sends the print job over tcp
this spooler works on both windows and linux. essentially, it watches a 
directory for txt files which it then processes according to rules
in the label configuration file
