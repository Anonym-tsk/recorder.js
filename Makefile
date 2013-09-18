MXMLC = "mxmlc"

build:
	$(MXMLC) -debug=false -static-link-runtime-shared-libraries=true -optimize=true -o recorder.swf -file-specs flash/FlashRecorder.as

clean:
	rm recorder.swf
