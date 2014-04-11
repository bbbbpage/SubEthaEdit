//
//  PlainTextEditor.m
//  SubEthaEdit
//
//  Created by Dominik Wagner on Tue Apr 06 2004.
//  Copyright (c) 2004-2007 TheCodingMonkeys. All rights reserved.
//

#import "FindReplaceController.h"
#import "SEEDocumentController.h"
#import "PlainTextEditor.h"
#import "PlainTextDocument.h"
#import "PlainTextWindowController.h"
#import "LayoutManager.h"
#import "SEETextView.h"
#import "GutterRulerView.h"
#import "DocumentMode.h"
#import "TCMMMUserManager.h"
#import "TCMMMUser.h"
#import "TCMMMUserSEEAdditions.h"
#import "TCMMMSession.h"
#import "TCMMMTransformator.h"
#import "SEEPlainTextEditorScrollView.h"
#import "PopUpButtonCell.h"
#import "RadarScroller.h"
#import "SelectionOperation.h"
#import "UndoManager.h"
#import "BorderedTextField.h"
#import "DocumentModeManager.h"
#import "AppController.h"
#import "InsetTextFieldCell.h"
#import <OgreKit/OgreKit.h>
#import "SyntaxDefinition.h"
#import "SyntaxHighlighter.h"
#import "ScriptTextSelection.h"
#import "NSMenuTCMAdditions.h"
#import "NSImageTCMAdditions.h"
#import "NSMutableAttributedStringSEEAdditions.h"
#import "FoldableTextStorage.h"
#import "FoldedTextAttachment.h"
#import "URLBubbleWindow.h"
#import "SEEFindAndReplaceViewController.h"
#import <objc/objc-runtime.h>
#import "SEEPlainTextEditorTopBarViewController.h"
#import "SEEOverlayView.h"
#import "NSLayoutConstraint+TCMAdditions.h"

NSString * const PlainTextEditorDidFollowUserNotification = @"PlainTextEditorDidFollowUserNotification";
NSString * const PlainTextEditorDidChangeSearchScopeNotification = @"PlainTextEditorDidChangeSearchScopeNotification";

@interface NSTextView (PrivateAdditions)
- (BOOL)	_isUnmarking;
@end

@interface NSMenu (UndefinedStuff)
- (NSMenu *)bottomPart;
@end

@implementation NSMenu (UndefinedStuff)
- (NSMenu *)bottomPart
{
    NSMenu *newMenu = [[NSMenu new] autorelease];
    NSArray *items = [self itemArray];
    int count = [items count];
    int index = count - 1;

    while (index >= 0)
    {
        if ([[items objectAtIndex:index] isSeparatorItem])
        {
            index++; break;
        }

        index--;
    }

    while (index < count)
    {
        [newMenu addItem:[[[items objectAtIndex:index] copy] autorelease]];
        index++;
    }
    return newMenu;
}


@end


@interface PlainTextEditor ()

@property (nonatomic, strong) IBOutlet NSView *O_editorView;
@property (nonatomic, assign) IBOutlet SEEOverlayView *O_bottomStatusBarView;
@property (nonatomic, assign) IBOutlet NSButton *shareInviteUsersButtonOutlet;
@property (nonatomic, assign) IBOutlet NSButton *shareAnnounceButtonOutlet;
@property (nonatomic, assign) IBOutlet NSObjectController *ownerController;
@property (nonatomic, strong) NSArray *topLevelNibObjects;
@property (nonatomic, strong) NSViewController *bottomOverlayViewController;
@property (nonatomic, strong) NSViewController *topOverlayViewController;
@property (nonatomic, strong) SEEFindAndReplaceViewController *findAndReplaceController;
@property (nonatomic, strong) SEEPlainTextEditorTopBarViewController *topBarViewController;
@property (nonatomic, strong) NSArray *topBlurBackgroundConstraints;
@property (nonatomic, strong) SEEOverlayView *topBlurLayerView;
@property (nonatomic, strong) NSArray *bottomBlurBackgroundConstraints;
@property (nonatomic, strong) SEEOverlayView *bottomBlurLayerView;
- (void)	TCM_updateBottomStatusBar;
- (float)pageGuidePositionForColumns:(int)aColumns;
@end

@implementation PlainTextEditor

- (id)initWithWindowControllerTabContext:(PlainTextWindowControllerTabContext *)aWindowControllerTabContext splitButton:(BOOL)aFlag
{
    self = [super init];

    if (self) {
        I_windowControllerTabContext = aWindowControllerTabContext;
        I_flags.hasSplitButton = aFlag;
        I_flags.showTopStatusBar = NO;
        I_flags.showBottomStatusBar = NO;
        I_flags.pausedProcessing = NO;
		I_storedSelectedRanges = [NSMutableArray new];

        [self setFollowUserID:nil];

		NSArray *topLevelNibObjects = nil;
        [[NSBundle mainBundle] loadNibNamed:@"PlainTextEditor" owner:self topLevelObjects:&topLevelNibObjects];
		self.topLevelNibObjects = topLevelNibObjects;

		[self loadViewPostprocessing];
    }

    return self;
}

- (void)prepareForDealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:[I_windowControllerTabContext document] name:NSTextViewDidChangeSelectionNotification object:I_textView];
    [[NSNotificationCenter defaultCenter] removeObserver:[I_windowControllerTabContext document] name:NSTextDidChangeNotification object:I_textView];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
	// release the objects that are bound so we get dealloced later
	self.ownerController.content = nil;
	self.topLevelNibObjects = nil;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:[I_windowControllerTabContext document] name:NSTextViewDidChangeSelectionNotification object:I_textView];
    [[NSNotificationCenter defaultCenter] removeObserver:[I_windowControllerTabContext document] name:NSTextDidChangeNotification object:I_textView];
    [[NSNotificationCenter defaultCenter] removeObserver:self];


    [I_textView setDelegate:nil];
    [I_textView setEditor:nil];     // in case our editor outlives us
	[I_textView release];

    [I_textContainer release];
    [I_radarScroller release];
    [I_followUserID release];
    [I_storedSelectedRanges release];
    [I_storedPosition release];

    [self.O_editorView setNextResponder:nil];
	self.topLevelNibObjects = nil;
	self.O_editorView = nil;

    [super dealloc];
}

- (BOOL)hitTestOverlayViewsWithEvent:(NSEvent *)aEvent {
	BOOL result = NO;
	NSPoint eventLocationInWindow = aEvent.locationInWindow;
	
	if ([self.topBlurLayerView hitTest:[self.topBlurLayerView.superview convertPoint:eventLocationInWindow fromView:nil]] != nil) {
		result = YES;
	} else if ([self.bottomBlurLayerView hitTest:[self.bottomBlurLayerView.superview convertPoint:eventLocationInWindow fromView:nil]] != nil) {
		result = YES;
	}
	return result;
}

- (void)participantsDidChange:(NSNotification *)aNotification
{
	[self TCM_updateNumberOfActiveParticipants];
}


- (void)sessionWillChange:(NSNotification *)aNotification
{
    PlainTextDocument *document = [self document];

    [[NSNotificationCenter defaultCenter] removeObserver:self name:TCMMMSessionParticipantsDidChangeNotification object:[document session]];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TCMMMSessionDidChangeNotification object:[document session]];
}


- (void)sessionDidChange:(NSNotification *)aNotification
{
	BOOL isServer = [[[self document] session] isServer];
	self.canAnnounceAndShare = isServer;
	
	[self TCM_updateLocalizedToolTips];
	[self TCM_updateNumberOfActiveParticipants];

    [[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(participantsDidChange:)
												 name:TCMMMSessionParticipantsDidChangeNotification
											   object:[[self document] session]];

    [[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(documentSessionPropertysDidUpdate:)
												 name:TCMMMSessionDidChangeNotification
											   object:[[self document] session]];
}


- (void)documentSessionPropertysDidUpdate:(NSNotification *)aNotification {
	[self TCM_updateLocalizedToolTips];
	[self updateAnnounceButton];
}

- (void)loadViewSetupBarsAndOverlays {
	// topbarviewcontroller
	self.topBarViewController = [[SEEPlainTextEditorTopBarViewController alloc] initWithPlainTextEditor:self];
	[self.topBarViewController updateColorsForIsDarkBackground:[self hasDarkBackground]];
	[self.topBarViewController setSplitButtonVisible:NO];
	self.topBarViewController.splitButtonVisible = I_flags.hasSplitButton;
	[self.topBarViewController setVisible:I_flags.showTopStatusBar];
	[self.O_editorView addSubview:self.topBarViewController.view];
	
	// generate top blur layer
	self.topBlurLayerView = ({
		SEEOverlayView *view = [[SEEOverlayView alloc] initWithFrame:NSZeroRect];
		NSView *containerView = self.O_editorView;
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[containerView addSubview:view];
		[containerView addConstraints:@[
										[NSLayoutConstraint TCM_constraintWithItem:view secondItem:containerView
																	equalAttribute:NSLayoutAttributeLeft],
										[NSLayoutConstraint TCM_constraintWithItem:view secondItem:containerView
																	equalAttribute:NSLayoutAttributeRight],
										[NSLayoutConstraint TCM_constraintWithItem:view secondItem:containerView
																	equalAttribute:NSLayoutAttributeTop],
										]];
		self.topBlurBackgroundConstraints = @[
											  [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1.0 constant:0]
											  ];
		[containerView addConstraints:self.topBlurBackgroundConstraints];
		//		view.layer.backgroundColor = [[[NSColor redColor] colorWithAlphaComponent:0.8] CGColor];
		view.backgroundBlurActive = YES;
		view.brightnessAdjustForInactiveWindowState = 0.7;
		view;
	});
	
	
	// change the top status bar to use constraints
	{
		NSView *statusBarView = self.topBarViewController.view;
		NSView *containerView = self.topBlurLayerView;
		[statusBarView removeFromSuperview];
		
		[statusBarView setTranslatesAutoresizingMaskIntoConstraints:NO];
		[containerView addSubview:statusBarView];
		[containerView addConstraints:@[
										[NSLayoutConstraint TCM_constraintWithItem:statusBarView secondItem:containerView equalAttribute:NSLayoutAttributeLeft],
										[NSLayoutConstraint TCM_constraintWithItem:statusBarView secondItem:containerView
																	equalAttribute:NSLayoutAttributeRight],
										[NSLayoutConstraint TCM_constraintWithItem:statusBarView secondItem:containerView equalAttribute:NSLayoutAttributeBottom],
										[NSLayoutConstraint constraintWithItem:statusBarView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeWidth multiplier:1.0 constant:CGRectGetHeight(statusBarView.bounds)],
										]];
		[self updateTopPinConstraints];
	}
	
	// generate bottom blur layer
	self.bottomBlurLayerView = ({
		SEEOverlayView *view = [[SEEOverlayView alloc] initWithFrame:NSZeroRect];
		NSView *containerView = self.O_editorView;
		view.translatesAutoresizingMaskIntoConstraints = NO;
		[containerView addSubview:view];
		[containerView addConstraints:@[
										[NSLayoutConstraint TCM_constraintWithItem:view secondItem:containerView
																	equalAttribute:NSLayoutAttributeLeft],
										[NSLayoutConstraint TCM_constraintWithItem:view secondItem:containerView
																	equalAttribute:NSLayoutAttributeRight],
										[NSLayoutConstraint TCM_constraintWithItem:view secondItem:containerView
																	equalAttribute:NSLayoutAttributeBottom],
										]];
		self.bottomBlurBackgroundConstraints = @[
												 [NSLayoutConstraint constraintWithItem:view attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1.0 constant:0]
												 ];
		[containerView addConstraints:self.bottomBlurBackgroundConstraints];
		//		view.layer.backgroundColor = [[[NSColor redColor] colorWithAlphaComponent:0.8] CGColor];
		view.backgroundBlurActive = YES;
		view.brightnessAdjustForInactiveWindowState = 0.7;
		view;
	});
	
	// change the bottom status bar to use constraints
	{
		NSView *statusBarView = self.O_bottomStatusBarView;
		NSView *containerView = self.bottomBlurLayerView;
		[statusBarView removeFromSuperview];
		
		// configure truncade mode
		[O_tabStatusPopUpButton.cell setLineBreakMode:NSLineBreakByTruncatingMiddle];
		[O_encodingPopUpButton.cell setLineBreakMode:NSLineBreakByTruncatingMiddle];
		
		// adjust sizes for german if necessary
		if ([[[NSBundle mainBundle] preferredLocalizations].firstObject isEqual:@"German"]) {
			// adjust frames
			CGFloat points = 20.0;
			O_tabStatusPopUpButton.frame = ({
				NSRect frame = O_tabStatusPopUpButton.frame;
				frame.size.width += points;
				frame;
			});
			O_lineEndingPopUpButton.frame = NSOffsetRect(O_lineEndingPopUpButton.frame, points, 0);
			O_encodingPopUpButton.frame = ({
				NSRect frame = O_encodingPopUpButton.frame;
				frame.size.width -= points;
				frame.origin.x += points;
				frame;
			});
		}
		
		[statusBarView setTranslatesAutoresizingMaskIntoConstraints:NO];
		[statusBarView setAutoresizesSubviews:YES];
		[containerView addSubview:statusBarView];
		[containerView addConstraints:@[
										[NSLayoutConstraint TCM_constraintWithItem:statusBarView secondItem:containerView
																	equalAttribute:NSLayoutAttributeRight],
										[NSLayoutConstraint TCM_constraintWithItem:statusBarView secondItem:containerView equalAttribute:NSLayoutAttributeLeft],
										[NSLayoutConstraint TCM_constraintWithItem:statusBarView secondItem:containerView
																	equalAttribute:NSLayoutAttributeBottom],
										[NSLayoutConstraint constraintWithItem:statusBarView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeWidth multiplier:1.0 constant:CGRectGetHeight(statusBarView.bounds)],
										]];
		[statusBarView setHidden:!I_flags.showBottomStatusBar];
	}
	
	// setup all the UI for the bottom bar
	NSView *bottomStatusBarView = self.O_bottomStatusBarView;
	bottomStatusBarView.layer.backgroundColor = [[NSColor darkOverlayBackgroundColorBackgroundIsDark:NO] CGColor];
	
	[I_textView setPostsFrameChangedNotifications:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textViewFrameDidChange:) name:NSViewFrameDidChangeNotification object:I_textView];
	
    [O_windowWidthTextField setHasRightBorder:NO];
    [O_windowWidthTextField setHasLeftBorder:YES];
	
    DocumentModeMenu *menu = [[DocumentModeMenu new] autorelease];
    [menu configureWithAction:@selector(chooseMode:) alternateDisplay:NO];
    [[O_modePopUpButton cell] setMenu:menu];
	
    EncodingMenu *fileEncodingsSubmenu = [[EncodingMenu new] autorelease];
    [fileEncodingsSubmenu configureWithAction:@selector(selectEncoding:)];
    [[[fileEncodingsSubmenu itemArray] lastObject] setTarget:self];
    [[[fileEncodingsSubmenu itemArray] lastObject] setAction:@selector(showCustomizeEncodingPanel:)];
    [[O_encodingPopUpButton cell] setMenu:fileEncodingsSubmenu];
	
    NSMenu *lineEndingMenu = [[NSMenu new] autorelease];
    [O_lineEndingPopUpButton setPullsDown:YES];
    // insert title item of pulldown popupbutton
    [lineEndingMenu addItem:[[[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""] autorelease]];
    NSMenuItem *item = nil;
    SEL chooseLineEndings = @selector(chooseLineEndings:);
    NSEnumerator *formatSubmenuItems = [[[[[NSApp mainMenu] itemWithTag:FormatMenuTag] submenu] itemArray] objectEnumerator];
	
    while ((item = [formatSubmenuItems nextObject]))
    {
        if ([item hasSubmenu] && [[[[item submenu] itemArray] objectAtIndex:0] action] == chooseLineEndings)
        {
            NSEnumerator *interestingItems = [[[item submenu] itemArray] objectEnumerator];
            NSMenuItem *innerItem = nil;
			
            while ((innerItem = [interestingItems nextObject]))
            {
                if ([innerItem isSeparatorItem])
                {
                    [lineEndingMenu addItem:[NSMenuItem separatorItem]];
                }
                else
                {
                    item = [[[NSMenuItem alloc] initWithTitle:[innerItem title] action:[innerItem action] keyEquivalent:@""] autorelease];
                    [item setTarget:[innerItem target]];
                    [item setTag:[innerItem tag]];
                    [lineEndingMenu addItem:item];
                }
            }
            break;
        }
    }
    [[O_lineEndingPopUpButton cell] setMenu:lineEndingMenu];
	
    [O_tabStatusPopUpButton setPullsDown:YES];
    NSMenu *tabMenu = [[NSMenu new] autorelease];
    // insert title item of pulldown popupbutton
    [tabMenu addItem:[[[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""] autorelease]];
    formatSubmenuItems = [[[[[NSApp mainMenu] itemWithTag:FormatMenuTag] submenu] itemArray] objectEnumerator];
    BOOL copyItems = NO;
	
    while ((item = [formatSubmenuItems nextObject]))
    {
        if ([item action] == @selector(toggleUsesTabs:)) copyItems = YES;
		
        if (copyItems)
        {
            if ([item isSeparatorItem])
            {
                [tabMenu addItem:[NSMenuItem separatorItem]];
            }
            else
            {
                NSMenuItem *newItem = [tabMenu addItemWithTitle:[item title] action:[item action] keyEquivalent:@""];
                [newItem setTarget:[item target]];
                [newItem setTag:[item tag]];
				
                if ([item hasSubmenu])
                {
                    [newItem setSubmenu:[[[item submenu] copy] autorelease]];
                }
            }
        }
    }
    [[O_tabStatusPopUpButton cell] setMenu:tabMenu];
	
	[self updateTopScrollViewInset];
	[self updateBottomScrollViewInset];
}

- (void)loadViewPostprocessing {
    [self loadViewSetupBarsAndOverlays];
	
	[self TCM_updateBottomStatusBar];
	

	PlainTextDocument *document = [self document];

	NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
	
    if (document) {
        [notificationCenter addObserver:self selector:@selector(defaultParagraphStyleDidChange:)
								   name:PlainTextDocumentDefaultParagraphStyleDidChangeNotification
								 object:document];
        [notificationCenter addObserver:self selector:@selector(userDidChangeSelection:)
								   name:PlainTextDocumentUserDidChangeSelectionNotification
								 object:document];
        [notificationCenter addObserver:self selector:@selector(plainTextDocumentDidChangeEditStatus:)
								   name:PlainTextDocumentDidChangeEditStatusNotification
								 object:document];
        [notificationCenter addObserver:self selector:@selector(plainTextDocumentUserDidChangeSelection:)
								   name:PlainTextDocumentUserDidChangeSelectionNotification
								 object:document];
        [notificationCenter addObserver:self selector:@selector(sessionWillChange:)
								   name:PlainTextDocumentSessionWillChangeNotification
								 object:document];
        [notificationCenter addObserver:self selector:@selector(sessionDidChange:)
								   name:PlainTextDocumentSessionDidChangeNotification
								 object:document];
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(TCM_updateBottomStatusBar) name:@"AfterEncodingsListChanged" object:nil];

    I_radarScroller = [RadarScroller new];
    [O_scrollView setHasVerticalScroller:YES];
    [O_scrollView setVerticalScroller:I_radarScroller];

    NSRect frame = NSZeroRect;
    frame.size  = [O_scrollView contentSize];

	[self.shareInviteUsersButtonOutlet sendActionOn:NSLeftMouseDownMask];

    LayoutManager *layoutManager = [LayoutManager new];
    [[document textStorage] addLayoutManager:layoutManager];

    I_textContainer =  [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(frame.size.width, FLT_MAX)];

    I_textView = ({
		SEETextView *textView = [[SEETextView alloc] initWithFrame:frame textContainer:I_textContainer];
		[textView setEditor:self];
		[textView setHorizontallyResizable:NO];
		[textView setVerticallyResizable:YES];
		[textView setAutoresizingMask:NSViewWidthSizable];
		[textView setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
		[textView setSelectable:YES];
		[textView setEditable:YES];
		[textView setRichText:NO];
		[textView setImportsGraphics:NO];
		[textView setUsesFontPanel:NO];
		[textView setUsesRuler:YES];
		[textView setUsesFindPanel:YES];
		[textView setAllowsUndo:NO];
		[textView setSmartInsertDeleteEnabled:NO];
		[textView turnOffLigatures:self];
		[textView setLinkTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSCursor pointingHandCursor], NSCursorAttributeName, nil]];
		[textView setDelegate:self];
		textView;
	});
	
    [I_textContainer setHeightTracksTextView:NO];
    [I_textContainer setWidthTracksTextView:YES];
    [layoutManager addTextContainer:I_textContainer];

    [O_scrollView setVerticalRulerView:[[[GutterRulerView alloc] initWithScrollView:O_scrollView orientation:NSVerticalRuler] autorelease]];
    [O_scrollView setHasVerticalRuler:YES];

    [[O_scrollView verticalRulerView] setRuleThickness:42.];

    [O_scrollView setDocumentView:I_textView];
    [[O_scrollView verticalRulerView] setClientView:I_textView];
    [[O_scrollView contentView] setPostsBoundsChangedNotifications:YES];
	[I_textView setFrameOrigin:CGPointZero];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(contentViewBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:[O_scrollView contentView]];

    [layoutManager release];

    [I_textView setDefaultParagraphStyle:[document defaultParagraphStyle]];

    [[NSNotificationCenter defaultCenter] addObserver:document selector:@selector(textViewDidChangeSelection:) name:NSTextViewDidChangeSelectionNotification object:I_textView];
    [[NSNotificationCenter defaultCenter] addObserver:document selector:@selector(textDidChange:) name:NSTextDidChangeNotification object:I_textView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textDidChange:) name:PlainTextDocumentDidChangeTextStorageNotification object:document];

	// Adding a second view hierachy to include this controller into the responder chain
    NSView *view = [[[NSView alloc] initWithFrame:[self.O_editorView frame]] autorelease];
    [view setAutoresizesSubviews:YES];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [view addSubview:self.O_editorView];
    [view setPostsFrameChangedNotifications:YES];
	[view setWantsLayer:self.O_editorView.wantsLayer];
    [self.O_editorView setNextResponder:self];
	
    [self setNextResponder:view];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewFrameDidChange:) name:NSViewFrameDidChangeNotification object:view];
    self.O_editorView = view;
	
	// localize the announce status menu - take from main menu
	NSMenuItem *accessMenuItem = [[AppController sharedInstance] accessControlMenuItem];
	NSMenu *accessPopUpMenu = self.shareAnnounceButtonOutlet.menu;
	NSInteger menuItemIndex = 0;
	for (NSMenuItem *item in [accessMenuItem.submenu itemArray]) {
		if (!item.isAlternate) {
			NSMenuItem *targetMenuItem = accessPopUpMenu.itemArray[menuItemIndex++];
			targetMenuItem.title = item.title;
			targetMenuItem.keyEquivalent = item.keyEquivalent;
			targetMenuItem.keyEquivalentModifierMask = item.keyEquivalentModifierMask;
		}
		if (menuItemIndex >= accessPopUpMenu.itemArray.count) break;
	}

	[self takeStyleSettingsFromDocument];
    [self takeSettingsFromDocument];
    [self setShowsChangeMarks:[document showsChangeMarks]];

	// set the right values for the status bars
	[self TCM_updateBottomStatusBar];
	[self.topBarViewController updateForSelectionDidChange];

	// make sure we start out right
	[self updateTopScrollViewInset];
	[self updateBottomScrollViewInset];

    // trigger the notfications for the first time
    [self sessionDidChange:nil];
    [self participantsDidChange:nil];
	
}


- (void)pushSelectedRanges
{
    [I_storedSelectedRanges addObject:[NSValue valueWithRange:[I_textView selectedRange]]];
}


- (void)popSelectedRanges
{
    NSValue *value = [I_storedSelectedRanges lastObject];

    if (value)
    {
        NSRange selectedRange = [value rangeValue];
        [I_textView setSelectedRange:RangeConfinedToRange(selectedRange, NSMakeRange(0, [[I_textView string] length]))];
        [I_storedSelectedRanges removeLastObject];
    }
    else
    {
        [I_textView setSelectedRange:NSMakeRange(0, 0)];
    }
}


- (void)adjustDisplayOfPageGuide
{
    PlainTextDocument *document = [self document];

    if (document)
    {
        DocumentMode *mode = [document documentMode];

        if ([[mode defaultForKey:DocumentModeShowPageGuidePreferenceKey] boolValue])
        {
            [(SEETextView *)I_textView setPageGuidePosition :[self pageGuidePositionForColumns:[[mode defaultForKey:DocumentModePageGuideWidthPreferenceKey] intValue]]];
        }
        else
        {
            [(SEETextView *)I_textView setPageGuidePosition : 0];
        }
    }
}

- (BOOL)hasDarkBackground {
	BOOL result = self.document.documentBackgroundColor.isDark;
	return result;
}

- (void)updateColorsForIsDarkBackground:(BOOL)isDark {
	[self.topBarViewController updateColorsForIsDarkBackground:isDark];
	// bottom bar
	NSColor *darkColor = [NSColor darkOverlayBackgroundColorBackgroundIsDark:isDark];
	NSColor *darkSeparatorColor = [NSColor darkOverlaySeparatorColorBackgroundIsDark:isDark];
	[O_windowWidthTextField setBorderColor:darkSeparatorColor];
	[self.O_bottomStatusBarView.layer setBackgroundColor:[darkColor CGColor]];
	
	[O_bottomBarSeparatorLineView.layer setBackgroundColor:[darkSeparatorColor CGColor]];
	for (PopUpButton *button in @[O_modePopUpButton,O_tabStatusPopUpButton, O_encodingPopUpButton, O_lineEndingPopUpButton]) {
		[button setLineColor:darkSeparatorColor];
	}
	
	// overlays?
}

- (void)takeStyleSettingsFromDocument
{
    PlainTextDocument *document = [self document];
    if (document)
    {
		BOOL isDark = [self hasDarkBackground];
        [[self textView] setBackgroundColor:[document documentBackgroundColor]];
		[self updateColorsForIsDarkBackground:isDark];
        NSColor *invisibleCharacterColor = [[document styleAttributesForScope:@"meta.invisible.character" languageContext:nil] objectForKey:NSForegroundColorAttributeName];
        [(LayoutManager *)[[self textView] layoutManager] setInvisibleCharacterColor : invisibleCharacterColor ? invisibleCharacterColor :[NSColor grayColor]];
    }
}


- (void)takeSettingsFromDocument
{
    PlainTextDocument *document = [self document];

    if (document)
    {
        [self setShowsInvisibleCharacters:[document showInvisibleCharacters]];
        [self setWrapsLines:[document wrapLines]];
        [self setShowsGutter:[document showsGutter]];
        [self setShowsTopStatusBar:[document showsTopStatusBar]];
        [self setShowsBottomStatusBar:[document showsBottomStatusBar]];
        [I_textView setEditable:[document isEditable]];
        [I_textView setContinuousSpellCheckingEnabled:[document isContinuousSpellCheckingEnabled]];

        DocumentMode *documentMode = [document documentMode];
        NSDictionary *attributeForDefaultKeyDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                                          DocumentModeGrammarCheckingPreferenceKey,            @"setGrammarCheckingEnabled:",
                                                          DocumentModeAutomaticLinkDetectionPreferenceKey,     @"setAutomaticLinkDetectionEnabled:",
                                                          DocumentModeAutomaticDashSubstitutionPreferenceKey,  @"setAutomaticDashSubstitutionEnabled:",
                                                          DocumentModeAutomaticQuoteSubstitutionPreferenceKey, @"setAutomaticQuoteSubstitutionEnabled:",
                                                          DocumentModeAutomaticTextReplacementPreferenceKey,   @"setAutomaticTextReplacementEnabled:",
                                                          DocumentModeAutomaticSpellingCorrectionPreferenceKey, @"setAutomaticSpellingCorrectionEnabled:",
                                                          nil];
        NSEnumerator *keyEnumerator = [attributeForDefaultKeyDictionary keyEnumerator];
        NSString *attributeString = nil;

        while ((attributeString = [keyEnumerator nextObject]))
        {
            NSString *defaultKey = [attributeForDefaultKeyDictionary objectForKey:attributeString];
            SEL attributeSetter = NSSelectorFromString(attributeString);

            if ([I_textView respondsToSelector:attributeSetter])
            {
                objc_msgSend(I_textView, attributeSetter, [[documentMode defaultForKey:defaultKey] boolValue]);
                //				NSLog(@"%s set %@ for %@ now %@",__FUNCTION__,attributeString, defaultKey, [documentMode defaultForKey:defaultKey]);
            }
        }
    }

	[self.topBarViewController updateSymbolPopUpContent];
	[self.topBarViewController updateForSelectionDidChange];
	
    [self TCM_updateBottomStatusBar];
    [self adjustDisplayOfPageGuide];
}


- (BOOL)isShowingFindAndReplaceInterface {
	BOOL result = self.findAndReplaceController && [self.topOverlayViewController isEqual:self.findAndReplaceController];
	return result;
}

- (void)adjustToScrollViewInsets {
	[I_textView adjustContainerInsetToScrollView];
	[[O_scrollView verticalRulerView] setNeedsDisplay:YES];
	[[[O_scrollView window] windowController] updateWindowMinSize];
}

- (float)pageGuidePositionForColumns:(int)aColumns
{
    NSFont *font = [[self document] fontWithTrait:0];
    CGFloat characterWidth = [@"n" sizeWithAttributes :[NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName]].width;

    return aColumns * characterWidth + [[I_textView textContainer] lineFragmentPadding] + [I_textView textContainerInset].width;
}


- (NSSize)desiredSizeForColumns:(int)aColumns rows:(int)aRows {
    NSSize result;
    NSFont *font = [[self document] fontWithTrait:0];
    CGFloat characterWidth = [@"n" sizeWithAttributes :[NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName]].width;

    result.width = characterWidth * aColumns + [[I_textView textContainer] lineFragmentPadding] * 2 + [I_textView textContainerInset].width * 2 + ([self.O_editorView bounds].size.width - [[I_textView enclosingScrollView] contentSize].width);

    result.height = [[I_textContainer layoutManager] defaultLineHeightForFont:font] * aRows +
	[I_textView textContainerInset].height * 2 +
	([self.O_editorView bounds].size.height - [[I_textView enclosingScrollView] contentSize].height);

    return result;
}


- (int)displayedRows
{
    int rows = 0;

    if ([self document])
    {
        NSFont *font = [[self document] fontWithTrait:0];
        rows = (int)(([[I_textView enclosingScrollView] contentSize].height - [I_textView textContainerInset].height * 2) / [[I_textView layoutManager] defaultLineHeightForFont:font]);
    }

    return rows;
}


- (int)displayedColumns
{
    int columns = 0;

    if ([self document])
    {
        NSFont *font = [[self document] fontWithTrait:0];
        CGFloat characterWidth = [@"n" sizeWithAttributes :[NSDictionary dictionaryWithObject:font forKey:NSFontAttributeName]].width;
        columns = (int)(([I_textView bounds].size.width - [I_textView textContainerInset].width * 2 - [[I_textView textContainer] lineFragmentPadding] * 2) / characterWidth);
    }

    return columns;
}

- (CGFloat)desiredMinHeight {
	CGFloat result = 50.0;
	SEEPlainTextEditorScrollView *scrollView = O_scrollView;
	result += scrollView.topOverlayHeight + scrollView.bottomOverlayHeight;
	return result;
}

#pragma mark - Editor Button Tooltips
- (void)TCM_updateLocalizedToolTips {
	self.localizedToolTipToggleParticipantsButton = ({
		NSString *string;
		if (self.hasBottomOverlayView) {
			string = NSLocalizedStringWithDefaultValue(@"TOOL_TIP_PARTICIPANTS_BUTTON_HIDE", nil, [NSBundle mainBundle], @"Hide Participants", @"Editor Tool Tip Participants Button - Hide");
		} else {
			string = NSLocalizedStringWithDefaultValue(@"TOOL_TIP_PARTICIPANTS_BUTTON_SHOW", nil, [NSBundle mainBundle], @"Show Participants", @"Editor Tool Tip Participants Button - Show");
		}
		string;
	});
	
	BOOL isServer = [[[self document] session] isServer];
	self.localizedToolTipShareInviteButton = ({
		NSString *string;
		if (isServer) {
			string = NSLocalizedStringWithDefaultValue(@"TOOL_TIP_SHARE_BUTTON_DEFAULT", nil, [NSBundle mainBundle], @"Share Document", @"Editor Tool Tip Share Invite Button - Share");
		} else {
			string = NSLocalizedStringWithDefaultValue(@"TOOL_TIP_SHARE_BUTTON_DISABLED", nil, [NSBundle mainBundle], @"Share Document (Disabled)", @"Editor Tool Tip Share Invite Button - Cannot share");
		}
		string;
	});
	
	self.localizedToolTipAnnounceButton = ({
		NSString *string;
		if (isServer) {
			if ([self.document isAnnounced]) {
				string = NSLocalizedStringWithDefaultValue(@"TOOL_TIP_ANNOUNCE_BUTTON_CONCEAL", nil, [NSBundle mainBundle], @"Conceal Document", @"Editor Tool Tip Announce Button - Conceal");
				
			} else {
				string = NSLocalizedStringWithDefaultValue(@"TOOL_TIP_ANNOUNCE_BUTTON_ANNOUNCE", nil, [NSBundle mainBundle], @"Announce Document", @"Editor Tool Tip Announce Button - Announce");
			}
		} else {
			string = NSLocalizedStringWithDefaultValue(@"TOOL_TIP_ANNOUNCE_BUTTON_DISABLED", nil, [NSBundle mainBundle], @"Announce Document (Disabled)", @"Editor Tool Tip Announce Button - Disabled");
		}
		string;
	});
}

- (void)TCM_updateNumberOfActiveParticipants {
    NSLayoutManager *layoutManager = [I_textView layoutManager];
	NSUInteger participantCount = [[[self document] session] participantCount];
	self.numberOfActiveParticipants = @(participantCount);
	self.showsNumberOfActiveParticipants = participantCount > 1;
	
	[layoutManager setAllowsNonContiguousLayout:(participantCount == 1)];
}

- (void)TCM_updateBottomStatusBar {
    if (I_flags.showBottomStatusBar)
    {
        PlainTextDocument *document = [self document];
        [O_tabStatusPopUpButton setTitle:[NSString stringWithFormat:NSLocalizedString(@"%@ (%d)", @"arrangement of Tab setting and tab width in Bottm Status Bar"), [document usesTabs] ? NSLocalizedString(@"TrueTab", @"Bottom status bar text for TrueTab setting"):NSLocalizedString(@"Spaces", @"Bottom status bar text for use Spaces (instead of Tab) setting"), [document tabWidth]]];
        [O_modePopUpButton selectItemAtIndex:[O_modePopUpButton indexOfItemWithTag:[[DocumentModeManager sharedInstance] tagForDocumentModeIdentifier:[[document documentMode] documentModeIdentifier]]]];

        [O_encodingPopUpButton selectItemAtIndex:[O_encodingPopUpButton indexOfItemWithTag:[document fileEncoding]]];

        int charactersPerLine = [self displayedColumns];
        [O_windowWidthTextField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"WindowWidth%d%@", @"WindowWidthArangementString"), charactersPerLine, [O_scrollView hasHorizontalScroller] ? @"":([document wrapMode] == DocumentModeWrapModeCharacters ? NSLocalizedString(@"CharacterWrap", @"As shown in bottom status bar") : NSLocalizedString(@"WordWrap", @"As shown in bottom status bar"))]];

        [O_lineEndingPopUpButton selectItemAtIndex:[O_lineEndingPopUpButton indexOfItemWithTag:[document lineEnding]]];
        NSString *lineEndingStatusString = @"";
        switch ([document lineEnding])
        {
            case LineEndingLF :
                lineEndingStatusString = @"LF";
                break;

            case LineEndingCR :
                lineEndingStatusString = @"CR";
                break;

            case LineEndingCRLF:
                lineEndingStatusString = @"CRLF";
                break;

            case LineEndingUnicodeLineSeparator:
                lineEndingStatusString = @"LSEP";
                break;

            case LineEndingUnicodeParagraphSeparator:
                lineEndingStatusString = @"PSEP";
                break;
        }
        [O_lineEndingPopUpButton setTitle:lineEndingStatusString];
    }
}

- (void)updateAnnounceButton {
	NSImage *announceImage = [NSImage imageNamed:@"BottomBarSharingIconAnnounce"];

	PlainTextDocument *document = self.document;
	TCMMMSession *session = document.session;
	switch (session.accessState) {
		case TCMMMSessionAccessLockedState:
			self.alternateAnnounceImage = announceImage;
			break;

		case TCMMMSessionAccessReadOnlyState:
			self.alternateAnnounceImage = [announceImage imageTintedWithColor:[NSColor orangeColor] invert:YES];
			break;

		case TCMMMSessionAccessReadWriteState:
			self.alternateAnnounceImage = [announceImage imageTintedWithColor:[NSColor blueColor] invert:YES];
			break;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
		default:
			self.alternateAnnounceImage = announceImage;
			break;
#pragma clang diagnostic pop

	}

	NSInteger buttonState = document.isAnnounced?NSOnState:NSOffState;
	[self.shareAnnounceButtonOutlet setState:NSOffState]; // This is realy dirty!
	// need to make the state switch in order force alternate image update in a layer backed view hierarchy on 10.9.1
	[self.shareAnnounceButtonOutlet setState:buttonState];
}


- (NSView *)editorView
{
    return self.O_editorView;
}


- (NSTextView *)textView
{
    return I_textView;
}


- (PlainTextDocument *)document {
    return (PlainTextDocument *)[I_windowControllerTabContext document];
}


- (void)setWindowControllerTabContext:(PlainTextWindowControllerTabContext *)aContext {
    I_windowControllerTabContext = aContext;
}

- (PlainTextWindowControllerTabContext *)windowControllerTabContext {
	return I_windowControllerTabContext;
}

- (void)updateSplitButtonForIsSplit:(BOOL)aFlag
{
    if (I_flags.hasSplitButton) {
		self.topBarViewController.splitButtonShowsClose = aFlag;
    }
}


- (int)dentLineInTextView:(NSTextView *)aTextView withRange:(NSRange)aLineRange in:(BOOL)aIndent
{
    int changedChars = 0;
    static NSCharacterSet *spaceTabSet = nil;

    if (!spaceTabSet)
    {
        spaceTabSet = [NSCharacterSet whitespaceCharacterSet];
    }

    NSRange affectedCharRange = NSMakeRange(aLineRange.location, 0);
    NSString *replacementString = @"";
    NSTextStorage *textStorage = [aTextView textStorage];
    NSString *string = [textStorage string];
    int tabWidth = [[self document] tabWidth];

    if ([[self document] usesTabs])
    {
        if (aIndent)
        {
            // replace spaces with tabs and add one tab
            unsigned lastCharacter = aLineRange.location;

            while (lastCharacter < NSMaxRange(aLineRange) &&
                   [spaceTabSet characterIsMember:[string characterAtIndex:lastCharacter]])
                lastCharacter++;

            if (aLineRange.location != lastCharacter && lastCharacter < NSMaxRange(aLineRange))
            {
                affectedCharRange = NSMakeRange(aLineRange.location, lastCharacter - aLineRange.location);
                unsigned detabbedLength = [string detabbedLengthForRange:affectedCharRange
														  tabWidth						:tabWidth];

                replacementString = [NSString stringWithFormat:@"\t%@%@",
                                     [@"" stringByPaddingToLength : (int)detabbedLength / tabWidth
														withString: @"\t" startingAtIndex : 0],
                                     [@"" stringByPaddingToLength : (int)detabbedLength % tabWidth
													   withString : @" " startingAtIndex : 0]
									 ];

                if (affectedCharRange.length != [replacementString length] - 1)
                {
                    changedChars = [replacementString length] - affectedCharRange.length;
                }
                else
                {
                    affectedCharRange = NSMakeRange(aLineRange.location, 0);
                    replacementString = @"\t";
                    changedChars = 1;
                }
            }
            else
            {
                replacementString = @"\t";
                changedChars = 1;
            }
        }
        else
        {
            if ([string length] > aLineRange.location)
            {
                // replace spaces with tabs and remove one tab or the remaining whitespace
                unsigned lastCharacter = aLineRange.location;

                while (lastCharacter < NSMaxRange(aLineRange) &&
                       [spaceTabSet characterIsMember:[string characterAtIndex:lastCharacter]])
                    lastCharacter++;
                affectedCharRange = NSMakeRange(aLineRange.location, lastCharacter - aLineRange.location);

                if (aLineRange.location != lastCharacter && lastCharacter < NSMaxRange(aLineRange))
                {
                    affectedCharRange = NSMakeRange(aLineRange.location, lastCharacter - aLineRange.location);
                    unsigned detabbedLength = [string detabbedLengthForRange:affectedCharRange
															  tabWidth						:tabWidth];

                    replacementString = [NSString stringWithFormat:@"%@%@",
                                         [@"" stringByPaddingToLength : (int)detabbedLength / tabWidth
														   withString : @"\t" startingAtIndex : 0],
                                         [@"" stringByPaddingToLength : (int)detabbedLength % tabWidth
														   withString : @" " startingAtIndex : 0]
										 ];

                    if ([replacementString length] != affectedCharRange.length ||
                        ((int)detabbedLength / tabWidth) == 0)
                    {
                        if ((int)detabbedLength / tabWidth > 0)
                        {
                            replacementString = [replacementString substringWithRange:NSMakeRange(1, [replacementString length] - 1)];
                        }
                        else
                        {
                            replacementString = @"";
                        }

                        changedChars = [replacementString length] - affectedCharRange.length;
                    }
                    else
                    {
                        // this if is always true due to the ifs above
                        // if ([string characterAtIndex:aLineRange.location]==[@"\t" characterAtIndex:0]) {
                        affectedCharRange = NSMakeRange(aLineRange.location, 1);
                        changedChars = -1;
                        replacementString = @"";
                        // }
                    }
                }
                else
                {
                    changedChars = [replacementString length] - affectedCharRange.length;
                }
            }
        }
    }
    else
    {
        unsigned firstCharacter = aLineRange.location;

        // replace tabs with spaces
        while (firstCharacter < NSMaxRange(aLineRange))
        {
            unichar character;
            character = [string characterAtIndex:firstCharacter];

            if (character == [@" " characterAtIndex : 0])
            {
                firstCharacter++;
            }
            else if (character == [@"\t" characterAtIndex : 0])
            {
                changedChars += tabWidth - 1;
                firstCharacter++;
            }
            else
            {
                break;
            }
        }

        if (changedChars != 0)
        {
            NSRange affectedRange = NSMakeRange(aLineRange.location, firstCharacter - aLineRange.location);
            NSString *replacementString = [@" " stringByPaddingToLength : firstCharacter - aLineRange.location + changedChars
															 withString : @" " startingAtIndex : 0];

            if ([aTextView shouldChangeTextInRange:affectedRange
								 replacementString:replacementString])
            {
                NSAttributedString *attributedReplaceString = [[NSAttributedString alloc]
                                                               initWithString:replacementString
                                                               attributes:[aTextView typingAttributes]];

                [textStorage replaceCharactersInRange:affectedRange
                                 withAttributedString:attributedReplaceString];
                firstCharacter += changedChars;
                [attributedReplaceString release];
            }
        }

        if (aIndent)
        {
            changedChars += tabWidth;
            replacementString = [@" " stringByPaddingToLength : tabWidth
												   withString : @" " startingAtIndex : 0];
        }
        else
        {
            if (firstCharacter >= affectedCharRange.location + tabWidth)
            {
                affectedCharRange.length = tabWidth;
                changedChars -= tabWidth;
            }
            else
            {
                affectedCharRange.length = firstCharacter - affectedCharRange.location;
                changedChars -= affectedCharRange.length;
            }
        }
    }

    NSRange newRange = NSMakeRange(affectedCharRange.location, [replacementString length]);

    if (affectedCharRange.length > 0 || newRange.length > 0)
    {
        if ([aTextView shouldChangeTextInRange:affectedCharRange
							 replacementString:replacementString])
        {
            [textStorage replaceCharactersInRange:affectedCharRange
									   withString:replacementString];

            if (newRange.length > 0)
            {
//				[textStorage addAttribute:NSParagraphStyleAttributeName value:[aTextView defaultParagraphStyle] range:newRange];
                [textStorage addAttributes:[aTextView typingAttributes] range:newRange];
            }
        }
    }

    return changedChars;
}


- (void)dentParagraphsInTextView:(NSTextView *)aTextView in:(BOOL)aIndent
{
    if ([(FoldableTextStorage *)[aTextView textStorage] hasBlockeditRanges])
    {
        NSBeep();
    }
    else
    {
        NSRange affectedRange = [aTextView selectedRange];
		if (affectedRange.location != NSNotFound)
		{
			[aTextView setSelectedRange:NSMakeRange(affectedRange.location, 0)];
			NSRange lineRange = {};
			NSTextStorage *textStorage = [aTextView textStorage];
			NSString *string = [textStorage string];

			UndoManager *undoManager = [[self document] documentUndoManager];
			[undoManager beginUndoGrouping];
			{
				if (affectedRange.length == 0) // no selection, cursor position
				{
					int lengthChange = 0;
					[textStorage beginEditing];
					{
						lineRange = [string lineRangeForRange:affectedRange];
						lengthChange = [self dentLineInTextView:aTextView withRange:lineRange in:aIndent];
					}
					[textStorage endEditing];

					if (lengthChange > 0)
					{
						affectedRange.location += lengthChange;
					}
					else if (lengthChange < 0)
					{
						if (affectedRange.location - lineRange.location < ABS(lengthChange))
						{
							affectedRange.location = lineRange.location;
						}
						else
						{
							affectedRange.location += lengthChange;
						}
					}
					[aTextView setSelectedRange:affectedRange];
				}
				else
				{
					affectedRange = [string lineRangeForRange:affectedRange];
					[textStorage beginEditing];
					{
						lineRange.location = NSMaxRange(affectedRange) - 1;
						lineRange.length = 1;
						lineRange = [string lineRangeForRange:lineRange];
						int result = 0;
						int changedLength = 0;

						while (!DisjointRanges(lineRange, affectedRange))
						{
							result = [self dentLineInTextView:aTextView withRange:lineRange in:aIndent];

							changedLength += result;

							// special case
							if (lineRange.location == 0) break;

							lineRange = [string lineRangeForRange:NSMakeRange(lineRange.location - 1, 1)];
						}
						affectedRange.length += changedLength;
					}
					[textStorage endEditing];
					[aTextView didChangeText];

					if (NSMaxRange(affectedRange) > [textStorage length])
					{
						if (affectedRange.length > 0)
						{
							affectedRange = NSIntersectionRange(affectedRange, NSMakeRange(0, [textStorage length]));
						}
						else
						{
							affectedRange.location = [textStorage length];
						}
					}

					[aTextView setSelectedRange:affectedRange];
				}
			}
			[undoManager endUndoGrouping];
		}
	}
}


- (void)tabParagraphsInTextView:(NSTextView *)aTextView de:(BOOL)shouldDetab
{
    if ([(FoldableTextStorage *)[aTextView textStorage] hasBlockeditRanges])
    {
        NSBeep();
    }
    else
    {
        NSRange affectedRange = [aTextView selectedRange];
        [aTextView setSelectedRange:NSMakeRange(affectedRange.location, 0)];

        UndoManager *undoManager = [[self document] documentUndoManager];
        NSTextStorage *textStorage = [aTextView textStorage];
        NSString *string = [textStorage string];

        [undoManager beginUndoGrouping];

        if (affectedRange.length == 0)
        {
            affectedRange = NSMakeRange(0, [textStorage length]);
        }

        affectedRange = [string lineRangeForRange:affectedRange];

        affectedRange = [textStorage detab:shouldDetab
								inRange			:affectedRange
								tabWidth		:[[self document] tabWidth]
						   askingTextView	:aTextView];

        [aTextView setSelectedRange:affectedRange];

        [undoManager endUndoGrouping];
    }
}


- (void)updateViews
{
    [self.topBarViewController updateForSelectionDidChange];
    [self TCM_updateBottomStatusBar];
	[self TCM_updateLocalizedToolTips];
	[self updateAnnounceButton];
}

#pragma mark - locking

- (void)lock {
	[self.findAndReplaceController setEnabled:NO];
	[self.textView setEditable:NO];
}

- (void)unlock {
	[self.findAndReplaceController setEnabled:YES];
	[self.textView setEditable:YES];
}


#pragma mark - Overlay view support

+ (NSSet *)keyPathsForValuesAffectingHasBottomOverlayView
{
    return [NSSet setWithObjects:@"bottomOverlayViewController", nil];
}

- (BOOL)hasBottomOverlayView {
	return (self.bottomOverlayViewController != nil);
}

- (void)displayViewControllerInBottomArea:(NSViewController *)viewController {
	NSViewController *displayedViewController = self.bottomOverlayViewController;
	if (displayedViewController != viewController) {
		if (displayedViewController) {
			NSView *bottomOverlayView = displayedViewController.view;
			[bottomOverlayView removeFromSuperview];
			self.bottomOverlayViewController = nil;
		}

		if (viewController) {
			NSView *bottomOverlayView = viewController.view;
			NSView *containerview = self.bottomBlurLayerView;
			[containerview addSubview:bottomOverlayView];
			// width
			[containerview addConstraints:@[
											[NSLayoutConstraint TCM_constraintWithItem:bottomOverlayView secondItem:containerview equalAttribute:NSLayoutAttributeWidth],
											[NSLayoutConstraint TCM_constraintWithItem:bottomOverlayView secondItem:containerview equalAttribute:NSLayoutAttributeTop],
			 ]];

			self.bottomOverlayViewController = viewController;
		}
	}
	[self updateBottomScrollViewInset];
	[self updateBottomPinConstraints];
	[self TCM_updateLocalizedToolTips];
	[self adjustToScrollViewInsets];
}

- (BOOL)hasTopOverlayView {
	return (self.topOverlayViewController != nil);
}

- (void)updateTopPinConstraints {
	SEEOverlayView *blurView = self.topBlurLayerView;
	NSView *containerView = blurView.superview;
	[containerView removeConstraints:self.topBlurBackgroundConstraints];
	self.topBlurBackgroundConstraints = ({
		NSArray *constraints = nil;
		NSView *topOverlayView = self.topOverlayViewController.view;
		NSView *topBarView = self.topBarViewController.view;
		CGFloat offset = self.showsTopStatusBar ? NSHeight(topBarView.frame) : 0.0;
		if (!topOverlayView.superview) {
			constraints = @[[NSLayoutConstraint constraintWithItem:blurView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1.0 constant:offset]];
		} else { // -> (topOverlayView.superview) is true
			constraints = @[[NSLayoutConstraint constraintWithItem:blurView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:topOverlayView attribute:NSLayoutAttributeHeight multiplier:1.0 constant:offset]];
		}
		[containerView addConstraints:constraints];
		constraints;
	});
}

- (void)updateBottomPinConstraints {
	SEEOverlayView *blurView = self.bottomBlurLayerView;
	NSView *containerView = blurView.superview;
	[containerView removeConstraints:self.bottomBlurBackgroundConstraints];
	self.bottomBlurBackgroundConstraints = ({
		NSArray *constraints = nil;
		NSView *bottomOverlayView = self.bottomOverlayViewController.view;
		NSView *bottomBarView = self.O_bottomStatusBarView;
		CGFloat offset = self.showsBottomStatusBar ? NSHeight(bottomBarView.frame) : 0.0;
		if (!bottomOverlayView.superview) {
			constraints = @[[NSLayoutConstraint constraintWithItem:blurView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1.0 constant:offset]];
		} else { // -> (topOverlayView.superview) is true
			constraints = @[[NSLayoutConstraint constraintWithItem:blurView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:bottomOverlayView attribute:NSLayoutAttributeHeight multiplier:1.0 constant:offset]];
		}
		[containerView addConstraints:constraints];
		constraints;
	});
}

- (void)displayViewControllerInTopArea:(NSViewController *)aViewController {
	NSViewController *displayedViewController = self.topOverlayViewController;
	if (displayedViewController != aViewController) {
		if (displayedViewController) {
			NSView *overlayView = displayedViewController.view;
			[overlayView removeFromSuperview];
			self.topOverlayViewController = nil;
		}
		
		if (aViewController) {
			NSView *overlayView = aViewController.view;
			NSView *superview = self.topBarViewController.view.superview;
			[superview addSubview:overlayView];

			// width
			[superview addConstraint:[NSLayoutConstraint constraintWithItem:overlayView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:superview attribute:NSLayoutAttributeWidth multiplier:1 constant:0]];
			// pin to top
			[superview addConstraint:[NSLayoutConstraint constraintWithItem:overlayView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:superview attribute:NSLayoutAttributeTop multiplier:1 constant:0]];
			
			self.topOverlayViewController = aViewController;
		}
		[self updateTopPinConstraints];
		[self updateTopScrollViewInset];
	}
}

- (IBAction)toggleFindAndReplace:(id)aSender {
	BOOL isDisplayed = (self.topOverlayViewController && self.findAndReplaceController == self.topOverlayViewController);
	if (isDisplayed) {
		[self hideFindAndReplace:aSender];
	} else {
		[self showFindAndReplace:aSender];
	}
}

- (IBAction)showFindAndReplace:(id)aSender {
	if (![self.topOverlayViewController isKindOfClass:[SEEFindAndReplaceViewController class]]) {
		SEEFindAndReplaceViewController *viewController = [[SEEFindAndReplaceViewController alloc] init];
		viewController.plainTextWindowControllerTabContext = I_windowControllerTabContext;
		self.findAndReplaceController = viewController;
		[viewController release];
		[self displayViewControllerInTopArea:viewController];
	}
	[[self.textView window] makeFirstResponder:self.findAndReplaceController.findTextField];
}

- (IBAction)hideFindAndReplace:(id)aSender {
	if (self.findAndReplaceController &&
		self.findAndReplaceController == self.topOverlayViewController) {
		[self displayViewControllerInTopArea:nil];
		PlainTextEditor *editorToActivate = I_windowControllerTabContext.activePlainTextEditor;
		[self.textView.window makeFirstResponder:editorToActivate.textView];
	}
}



#pragma mark -
#pragma mark First Responder Actions

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    SEL selector = [menuItem action];

    if (selector == @selector(toggleWrap:))
    {
        [menuItem setState:[O_scrollView hasHorizontalScroller] ? NSOffState:NSOnState];
        return YES;
    }
    else if (selector == @selector(toggleTopStatusBar:))
    {
        [menuItem setState:[self showsTopStatusBar] ? NSOnState:NSOffState];
        return YES;
    }
    else if (selector == @selector(toggleShowsChangeMarks:))
    {
        BOOL showsChangeMarks = [self showsChangeMarks];
        [menuItem setState:showsChangeMarks ? NSOnState:NSOffState];
        return YES;
    }
    else if (selector == @selector(toggleShowInvisibles:))
    {
        [menuItem setState:[self showsInvisibleCharacters] ? NSOnState:NSOffState];
        return YES;
    }
    else if (selector == @selector(blockeditSelection:) || selector == @selector(endBlockedit:))
    {
        FoldableTextStorage *textStorage = (FoldableTextStorage *)[I_textView textStorage];

        if ([textStorage hasBlockeditRanges])
        {
            [menuItem setTitle:NSLocalizedString(@"MenuBlockeditEnd", @"End Blockedit in edit Menu")];
            [menuItem setKeyEquivalent:@"\e"];
            [menuItem setAction:@selector(endBlockedit:)];
            [menuItem setKeyEquivalentModifierMask:0];
            return YES;
        }

        [menuItem setTitle:NSLocalizedString(@"MenuBlockeditSelection", @"Blockedit Selection in edit Menu")];
        [menuItem setKeyEquivalent:@"B"];
        [menuItem setAction:@selector(blockeditSelection:)];
        [menuItem setKeyEquivalentModifierMask:NSCommandKeyMask | NSShiftKeyMask];
        return YES;
    }
    else if (selector == @selector(copyAsXHTML:))
    {
        return [I_textView selectedRange].length > 0;
    }

    return YES;
}


/*" Copies the current selection as XHTML to the pasteboard
 font is added, background and foreground color is used
 - if wrapping is off: <pre> is used
 on: leading whitespace is fixed via &nbsp;, <br /> is added for line break
 - if colorize syntax is on: <span style="color: ...;">, <strong> and <em> are used to style the text
 - if Show Changes is on: background is colored according to user color, <a title="name"> tags are added
 TODO: detab before exporting
 "*/

- (IBAction)copyAsXHTML:(id)aSender
{
    static NSDictionary *baseAttributeMapping;
    static NSDictionary *writtenByAttributeMapping;

    if (baseAttributeMapping == nil)
    {
        baseAttributeMapping = [NSDictionary dictionaryWithObjectsAndKeys:
                                [NSDictionary dictionaryWithObjectsAndKeys:
                                 @"<strong>", @"openTag",
                                 @"</strong>", @"closeTag", nil], @"Bold",
                                [NSDictionary dictionaryWithObjectsAndKeys:
                                 @"<em>", @"openTag",
                                 @"</em>", @"closeTag", nil], @"Italic",
                                [NSDictionary dictionaryWithObjectsAndKeys:
                                 @"<span style=\"color:%@;\">", @"openTag",
                                 @"</span>", @"closeTag", nil], @"ForegroundColor",
                                nil];
        [baseAttributeMapping retain];
        writtenByAttributeMapping = [NSDictionary dictionaryWithObjectsAndKeys:
                                     [NSDictionary dictionaryWithObjectsAndKeys:
                                      @"<span style=\"background-color:%@;\">", @"openTag",
                                      @"</span>", @"closeTag", nil], @"BackgroundColor",
                                     [NSDictionary dictionaryWithObjectsAndKeys:
                                      @"<a title=\"%@\">", @"openTag",
                                      @"</a>", @"closeTag", nil], @"WrittenBy",
                                     nil];
        [writtenByAttributeMapping retain];
    }

    NSRange selectedRange = [I_textView selectedRange];

    if (selectedRange.location != NSNotFound && selectedRange.length > 0)
    {
        NSMutableDictionary *mapping = [[baseAttributeMapping mutableCopy] autorelease];

        if ([self showsChangeMarks])
        {
            [mapping addEntriesFromDictionary:writtenByAttributeMapping];
        }

        PlainTextDocument *document = [self document];
        NSColor *backgroundColor = [document documentBackgroundColor];
        NSColor *foregroundColor = [document documentForegroundColor];
        NSTextStorage *textStorage = [I_textView textStorage];
        NSMutableAttributedString *attributedSubString = [[[textStorage attributedSubstringFromRange:selectedRange] mutableCopy] autorelease];
        NSAttributedString *foldingIconReplacementString = [[[NSAttributedString alloc] initWithPath:[[NSBundle mainBundle] pathForResource:@"FoldingBubbleText" ofType:@"rtf"] documentAttributes:nil] autorelease];
        [attributedSubString replaceAttachmentsWithAttributedString:foldingIconReplacementString];
        NSMutableAttributedString *attributedStringForXHTML = [attributedSubString attributedStringForXHTMLExportWithRange:NSMakeRange(0, [attributedSubString length]) foregroundColor:foregroundColor backgroundColor:backgroundColor];
        [attributedStringForXHTML detab:YES inRange:NSMakeRange(0, [attributedStringForXHTML length]) tabWidth:[document tabWidth] askingTextView:nil];

        if ([self wrapsLines])
        {
            [attributedStringForXHTML makeLeadingWhitespaceNonBreaking];
        }

        selectedRange.location = 0;

        NSString *fontString = @"";

        if ([[[self document] fontWithTrait:0] isFixedPitch] ||
            [@"Monaco" isEqualToString : [[[self document] fontWithTrait:0] fontName]])
        {
            fontString = @"font-size:small; font-family:monospace; ";
        }

        // pre or div?
        NSString *topLevelTag = ([self wrapsLines] ? @"div" : @"pre");

        NSMutableString *result = [[NSMutableString alloc] initWithCapacity:selectedRange.length * 2];
        [result appendFormat:@"<%@ style=\"text-align:left;color:%@; background-color:%@; border:solid black 1px; padding:0.5em 1em 0.5em 1em; overflow:auto;%@\">", topLevelTag, [foregroundColor HTMLString], [backgroundColor HTMLString], fontString];
        NSMutableString *content = [attributedStringForXHTML XHTMLStringWithAttributeMapping:mapping forUTF8:NO];

        if ([self wrapsLines])
        {
            [content addBRs];
        }

        [result appendString:content];
        [result appendFormat:@"</%@>", topLevelTag];
        [[NSPasteboard generalPasteboard] declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
        [[NSPasteboard generalPasteboard] setString:result forType:NSStringPboardType];
        [result release];
    }
    else
    {
        NSBeep();
    }
}


//- (IBAction)copyAsXHTML:(id)aSender {
//    NSRange selectedRange=[I_textView selectedRange];
//    if (selectedRange.location!=NSNotFound && selectedRange.length>0) {
//        PlainTextDocument *document=[self document];
//        NSColor *backgroundColor=[document documentBackgroundColor];
//        NSColor *foregroundColor=[document documentForegroundColor];
//        TextStorage *textStorage=(TextStorage *)[I_textView textStorage];
//        NSAttributedString *attributedStringForXHTML=[textStorage attributedStringForXHTMLExportWithRange:selectedRange foregroundColor:foregroundColor];
//        selectedRange.location=0;
//
//        NSRange foundRange;
//        NSMutableString *result=[[NSMutableString alloc] initWithCapacity:selectedRange.length*2];
//        [result appendFormat:@"<pre style=\"color:%@; background-color:%@; border: solid black 1px; padding: 0.5em 1em 0.5em 1em; overflow:auto;\">",[foregroundColor HTMLString],[backgroundColor HTMLString]];
//        NSDictionary *attributes=nil;
//        unsigned int index=selectedRange.location;
//        do {
//            NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
//            attributes=[attributedStringForXHTML attributesAtIndex:index
//                    longestEffectiveRange:&foundRange inRange:selectedRange];
//            index=NSMaxRange(foundRange);
//            NSString *contentString=[[[attributedStringForXHTML string] substringWithRange:foundRange] stringByReplacingEntities];
//            NSMutableString *styleString=[NSMutableString string];
//            if (attributes) {
//                NSString *htmlColor=[attributes objectForKey:@"ForegroundColor"];
//                if (htmlColor) {
//                    [styleString appendFormat:@"color:%@;",htmlColor];
//                }
//                NSNumber *traitMask=[attributes objectForKey:@"FontTraits"];
//                if (traitMask) {
//                    unsigned traits=[traitMask unsignedIntValue];
//                    if (traits & NSBoldFontMask) {
//                        [styleString appendString:@"font-weight:bold;"];
//                    }
//                    if (traits & NSItalicFontMask) {
//                        [styleString appendString:@"font-style:oblique;"];
//                    }
//                }
//                if ([styleString length]>0) {
//                    [result appendFormat:@"<span style=\"%@\">",styleString];
//                }
//            }
//            [result appendString:contentString];
//            if (attributes && [styleString length]>0) {
//                [result appendString:@"</span>"];
//            }
//
//            index=NSMaxRange(foundRange);
//            [pool release];
//        } while (index<NSMaxRange(selectedRange));
//        [result appendString:@"</pre>"];
//        [[NSPasteboard generalPasteboard] declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
//        [[NSPasteboard generalPasteboard] setString:result forType:NSStringPboardType];
//        [result release];
//    } else {
//        NSBeep();
//    }
//}

- (IBAction)blockeditSelection:(id)aSender
{
    NSRange selection = [I_textView selectedRange];
    FoldableTextStorage *textStorage = (FoldableTextStorage *)[I_textView textStorage];
    NSRange lineRange = [[textStorage string] lineRangeForRange:selection];
    NSDictionary *blockeditAttributes = [[I_textView delegate] blockeditAttributesForTextView:I_textView];

    [textStorage addAttributes:blockeditAttributes
						 range:lineRange];
    [I_textView setSelectedRange:NSMakeRange(selection.location, 0)];
    [textStorage setHasBlockeditRanges:YES];
}


- (IBAction)endBlockedit:(id)aSender
{
    FoldableTextStorage *textStorage = (FoldableTextStorage *)[I_textView textStorage];

    if ([textStorage hasBlockeditRanges])
    {
        [textStorage stopBlockedit];
    }
}


- (void)setShowsChangeMarks:(BOOL)aFlag
{
    LayoutManager *layoutManager = (LayoutManager *)[I_textView layoutManager];

    if ([layoutManager showsChangeMarks] != aFlag)
    {
        [layoutManager setShowsChangeMarks:aFlag];
        [[self document] setShowsChangeMarks:aFlag];
    }
}


- (BOOL)showsChangeMarks
{
    return [(LayoutManager *)[I_textView layoutManager] showsChangeMarks];
}


- (void)setShowsInvisibleCharacters:(BOOL)aFlag
{
    LayoutManager *layoutManager = (LayoutManager *)[I_textView layoutManager];

    [layoutManager setShowsInvisibles:aFlag];
    [[self document] setShowInvisibleCharacters:aFlag];
    [I_textView setNeedsDisplay:YES];
}


- (BOOL)showsInvisibleCharacters
{
    return [(LayoutManager *)[I_textView layoutManager] showsInvisibles];
}


- (IBAction)toggleShowInvisibles:(id)aSender
{
    [self setShowsInvisibleCharacters:![self showsInvisibleCharacters]];
}


- (void)setWrapsLines:(BOOL)aFlag
{
    if (aFlag != [self wrapsLines])
    {
        [self toggleWrap:self];
    }
}


- (BOOL)wrapsLines
{
    return ![O_scrollView hasHorizontalScroller];
}


- (IBAction)toggleWrap:(id)aSender
{
    if (![O_scrollView hasHorizontalScroller])
    {
        // turn wrap off
        [I_textContainer setWidthTracksTextView:NO];
        [I_textView setAutoresizingMask:NSViewNotSizable];
        [I_textContainer setContainerSize:NSMakeSize(FLT_MAX, FLT_MAX)];
        [I_textView setHorizontallyResizable:YES];
        [I_textView setNeedsDisplay:YES];
        [O_scrollView setNeedsDisplay:YES];
        [O_scrollView setHasHorizontalScroller:YES];
    }
    else
    {
        // turn wrap on
        [O_scrollView setHasHorizontalScroller:NO];
        [O_scrollView setNeedsDisplay:YES];
        [I_textContainer setWidthTracksTextView:YES];
        [I_textView setHorizontallyResizable:NO];
        [I_textView setAutoresizingMask:NSViewWidthSizable];
        NSRect frame = [I_textView frame];
        frame.size.width = [O_scrollView contentSize].width;
        [I_textView setFrame:frame];
        // this needs to be done if no text flows over the text view margins (SEE-364)
        [I_textContainer setContainerSize:NSMakeSize(NSWidth([I_textView frame]) - 2.0 *[I_textView textContainerInset].width, FLT_MAX)];
        [I_textView setNeedsDisplay:YES];
    }

    // fixes cursor position after layout change
    //    [I_textView updateInsertionPointStateAndRestartTimer:YES];

    [[self document] setWrapLines:[self wrapsLines]];
    [self TCM_updateBottomStatusBar];
}

- (IBAction)positionButtonAction:(id)aSender {
	[self positionClick:aSender];
}

- (IBAction)positionClick:(id)aSender
{
    if (([[NSApp currentEvent] type] == NSLeftMouseDown ||
         [[NSApp currentEvent] type] == NSLeftMouseUp))
    {
        if ([[NSApp currentEvent] clickCount] == 1)
        {
            [I_textView doCommandBySelector:@selector(centerSelectionInVisibleArea:)];
        }
        else if ([[NSApp currentEvent] clickCount] > 1)
        {
            [[FindReplaceController sharedInstance] orderFrontGotoPanel:self];
        }
    }
}


- (BOOL)showsGutter
{
    return [O_scrollView rulersVisible];
}


- (void)setShowsGutter:(BOOL)aFlag
{
    [O_scrollView setRulersVisible:aFlag];
    [self TCM_updateBottomStatusBar];
}


#define STATUSBARSIZE 18.

- (void)updateTopScrollViewInset {
	CGFloat result = 0.0;
	if (self.showsTopStatusBar) {
		result += NSHeight(self.topBarViewController.view.frame);
	}
	if (self.topOverlayViewController.view) {
		[self.topOverlayViewController.view.window layoutIfNeeded];
		result += NSHeight(self.topOverlayViewController.view.frame);
	}
	O_scrollView.topOverlayHeight = result;
	[self adjustToScrollViewInsets];
}

- (void)updateBottomScrollViewInset {
	CGFloat result = 0.0;
	if (self.showsBottomStatusBar) {
		result += NSHeight(self.O_bottomStatusBarView.frame);
	}
	if (self.bottomOverlayViewController.view) {
		[self.bottomOverlayViewController.view.window layoutIfNeeded];
		result += NSHeight(self.bottomOverlayViewController.view.frame);
	}
	O_scrollView.bottomOverlayHeight = result;
	[self adjustToScrollViewInsets];
}

- (BOOL)showsTopStatusBar {
    return I_flags.showTopStatusBar;
}


- (void)setShowsTopStatusBar:(BOOL)aFlag {
    if (I_flags.showTopStatusBar != aFlag)
    {
        I_flags.showTopStatusBar = !I_flags.showTopStatusBar;

		[self.topBarViewController setVisible:I_flags.showTopStatusBar];
		[self.topBarViewController.view setNeedsDisplay:YES];
		
		[[O_scrollView verticalRulerView] setNeedsDisplay:YES];
        [[self document] setShowsTopStatusBar:aFlag];
		[self updateTopScrollViewInset];
		[self updateTopPinConstraints];
    }
}


- (BOOL)showsBottomStatusBar {
    return I_flags.showBottomStatusBar;
}

- (void)setShowsBottomStatusBar:(BOOL)aFlag {
	
    if (I_flags.showBottomStatusBar != aFlag) {
        I_flags.showBottomStatusBar = !I_flags.showBottomStatusBar;
		
        [self.O_bottomStatusBarView setHidden:!I_flags.showBottomStatusBar];
        [self.O_bottomStatusBarView setNeedsDisplay:YES];

		[self updateBottomPinConstraints];
		[self TCM_updateBottomStatusBar];
		[self updateBottomScrollViewInset];
    }
}


- (void)setFollowUserID:(NSString *)userID
{
    if (!(I_followUserID == nil && userID == nil))
    {
        [I_followUserID autorelease];
        I_followUserID = [userID copy];
        [self scrollToUserWithID:userID];
        [self.topBarViewController updateForSelectionDidChange];

		[[NSNotificationCenter defaultCenter] postNotificationName:PlainTextEditorDidFollowUserNotification object:self];
    }
}


- (NSString *)followUserID
{
    return I_followUserID;
}


- (IBAction)toggleShowsChangeMarks:(id)aSender
{
    [self setShowsChangeMarks:![self showsChangeMarks]];
}


- (IBAction)toggleTopStatusBar:(id)aSender
{
    [self setShowsTopStatusBar:![self showsTopStatusBar]];
}


- (IBAction)shiftRight:(id)aSender
{
    [self dentParagraphsInTextView:I_textView in:YES];
}


- (IBAction)shiftLeft:(id)aSender
{
    [self dentParagraphsInTextView:I_textView in:NO];
}


- (IBAction)detab:(id)aSender
{
    [self tabParagraphsInTextView:I_textView de:YES];
}


- (IBAction)entab:(id)aSender
{
    [self tabParagraphsInTextView:I_textView de:NO];
}


- (IBAction)insertStateClose:(id)aSender
{
    SEETextView *textView = I_textView;
    NSRange selectedRange = [(FoldableTextStorage *)[I_textView textStorage] fullRangeForFoldedRange : [textView selectedRange]];

    FullTextStorage *fullTextStorage = [(FoldableTextStorage *)[I_textView textStorage] fullTextStorage];
    NSRange startRange = [fullTextStorage startRangeForStateAndIndex:selectedRange.location];

    if (startRange.location != NSNotFound)
    {
        NSString *autoend = [fullTextStorage attribute:kSyntaxHighlightingAutocompleteEndName atIndex:startRange.location effectiveRange:nil];

        if (autoend)
        {
            //TODO: check if leading is whitespaceonly. ifso, outdent to intentlevel of start
            NSString *textstorageString = [fullTextStorage string];
            NSRange targetLineRange = [textstorageString lineRangeForRange:selectedRange];
            NSRange whitespaceRange = [textstorageString rangeOfLeadingWhitespaceStartingAt:targetLineRange.location];

            if (NSMaxRange(whitespaceRange) >= selectedRange.location)
            {
                // we have leading whitespace indeed
                NSLog(@"%s got whitespace!", __FUNCTION__);
                // get Leading whitespace from start
                NSRange startLineRange = [textstorageString lineRangeForRange:startRange];
                NSRange startWhitespaceRange = [textstorageString rangeOfLeadingWhitespaceStartingAt:startLineRange.location];

                if (startWhitespaceRange.length > 0)
                {
                    autoend = [[textstorageString substringWithRange:startWhitespaceRange] stringByAppendingString:autoend];
                }

                [self selectRange:NSUnionRange(whitespaceRange, selectedRange)];
                NSLog(@"%s inserting ||%@||", __FUNCTION__, autoend);
                [I_textView insertText:autoend];
            }
            else
            {
                [I_textView insertText:autoend];
            }
        }
        else
        {
            NSBeep();
        }
    }
    else
    {
        NSBeep();
    }
}


- (IBAction)jumpToNextSymbol:(id)aSender
{
    SEETextView *textView = I_textView;
    PlainTextDocument *document = [self document];
    NSRange selectedRange = [(FoldableTextStorage *)[document textStorage] fullRangeForFoldedRange : [textView selectedRange]];
    NSRange change = [document rangeOfPrevious:NO
								symbolForRange:NSMakeRange(NSMaxRange(selectedRange), 0)];

    if (change.location == NSNotFound)
    {
        NSBeep();
    }
    else
    {
        [self selectRange:change];
    }
}


- (IBAction)jumpToPreviousSymbol:(id)aSender
{
    SEETextView *textView = I_textView;
    PlainTextDocument *document = [self document];
    NSRange selectedRange = [(FoldableTextStorage *)[document textStorage] fullRangeForFoldedRange : [textView selectedRange]];
    NSRange change = [[self document] rangeOfPrevious:YES
									   symbolForRange:NSMakeRange(selectedRange.location, 0)];

    if (change.location == NSNotFound)
    {
        NSBeep();
    }
    else
    {
        [self selectRange:change];
    }
}


- (IBAction)jumpToNextChange:(id)aSender
{
    SEETextView *textView = (SEETextView *)[self textView];
    PlainTextDocument *document = [self document];
    NSRange selectedRange = [(FoldableTextStorage *)[document textStorage] fullRangeForFoldedRange :[textView selectedRange]];
    unsigned maxrange = NSMaxRange(selectedRange);
    NSRange change = [[self document] rangeOfPrevious:NO
									   changeForRange:NSMakeRange(maxrange > 0 ? maxrange - 1 : maxrange, 0)];

    if (change.location == NSNotFound)
    {
        NSBeep();
    }
    else
    {
        [self selectRange:change];
    }
}


- (IBAction)jumpToPreviousChange:(id)aSender
{
    SEETextView *textView = (SEETextView *)[self textView];
    PlainTextDocument *document = [self document];
    NSRange selectedRange = [(FoldableTextStorage *)[document textStorage] fullRangeForFoldedRange :[textView selectedRange]];
    NSRange change = [[self document] rangeOfPrevious:YES
									   changeForRange:NSMakeRange(selectedRange.location, 0)];

    if (change.location == NSNotFound)
    {
        NSBeep();
    }
    else
    {
        [self selectRange:change];
    }
}


- (void)gotoLine:(unsigned)aLine {
    NSRange range = [[(FoldableTextStorage *)[I_textView textStorage] fullTextStorage] findLine:aLine];
    [self selectRangeInBackground:range];
}


- (void)gotoLineInBackground:(unsigned)aLine {
    NSRange range = [[(FoldableTextStorage *)[I_textView textStorage] fullTextStorage] findLine:aLine];
    [self selectRangeInBackground:range];
}


- (void)selectRange:(NSRange)aRange {
    [[I_textView window] makeKeyAndOrderFront:self];
	[[I_textView window] makeFirstResponder:I_textView];
	[I_windowControllerTabContext setActivePlainTextEditor:self];
    [self selectRangeInBackground:aRange];
}


- (void)selectRangeInBackground:(NSRange)aRange {
    [self selectRangeInBackgroundWithoutIndication:aRange expandIfFolded:YES];
	[I_textView showFindIndicatorForRange:[I_textView selectedRange]];
}


- (void)selectRangeInBackgroundWithoutIndication:(NSRange)aRange expandIfFolded:(BOOL)aFlag {
    FoldableTextStorage *ts = (FoldableTextStorage *)[I_textView textStorage];

    aRange = [ts foldedRangeForFullRange:aRange expandIfFolded:aFlag];
    NSRange range = RangeConfinedToRange(aRange, NSMakeRange(0, [ts length]));
    [I_textView scrollRangeToVisible:range];
    [I_textView setSelectedRange:range];

    if (!NSEqualRanges(range, aRange)) NSBeep();
}


- (BOOL)hasSearchScopeInFullRange:(NSRange)aRange {
	FullTextStorage *ts = [(FoldableTextStorage *)I_textView.textStorage fullTextStorage];
	__block BOOL result = NO;
	NSValue *searchValue = self.searchScopeValue;
	[ts enumerateAttribute:SEESearchScopeAttributeName inRange:aRange options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired usingBlock:^(id value, NSRange range, BOOL *stop) {
		if ([value containsObject:searchValue]) { // TODO: move down to full text storage
			*stop = YES;
			result = YES;
		}
	}];
	return result;
}

- (BOOL)hasSearchScope {
	BOOL result = NO;
	FullTextStorage *ts = [(FoldableTextStorage *)I_textView.textStorage fullTextStorage];
	result = [self hasSearchScopeInFullRange:[ts TCM_fullLengthRange]];
	return result;
}

- (NSString *)searchScopeRangeString {
	NSMutableArray *rangesArray = [NSMutableArray array];
	FullTextStorage *fullTextStorage = [(FoldableTextStorage *)I_textView.textStorage fullTextStorage];
	for (NSValue *value in I_textView.searchScopeRanges) {
		NSRange range = value.rangeValue;
		[rangesArray addObject:[fullTextStorage rangeStringForRange:range]];
	}
	NSString *result = [rangesArray componentsJoinedByString:@", "];
	return result;
}

- (NSValue *)searchScopeValue {
	NSValue *result = [NSValue valueWithPointer:self.textView];
	return result;
}

- (IBAction)addCurrentSelectionToSearchScope:(id)aSender {
	SEETextView *textView = I_textView;
	NSRange selectedRange = [textView selectedRange];
    FoldableTextStorage *ts = (FoldableTextStorage *)[textView textStorage];
	FullTextStorage *fts = [ts fullTextStorage];
    NSRange fullRange = [ts foldedRangeForFullRange:selectedRange];
	[fts addSearchScopeAttributeValue:self.searchScopeValue inRange:fullRange];
	[self adjustToChangesInSearchScope];
}

- (IBAction)clearSearchScope:(id)aSender {
	SEETextView *textView = I_textView;
    FoldableTextStorage *ts = (FoldableTextStorage *)[textView textStorage];
	FullTextStorage *fts = [ts fullTextStorage];
	NSValue *searchScopeValue = [self searchScopeValue];
	[fts removeSearchScopeAttributeValue:searchScopeValue fromRange:fts.TCM_fullLengthRange];
	[self adjustToChangesInSearchScope];
}

- (void)adjustToChangesInSearchScope {
	[[O_scrollView verticalRulerView] setNeedsDisplay:YES];
	[[NSNotificationCenter defaultCenter] postNotificationName:PlainTextEditorDidChangeSearchScopeNotification object:self userInfo:nil];
}

- (PlainTextWindowController *)plainTextWindowController {
	PlainTextWindowController *result = self.textView.window.windowController;
	if (![result isKindOfClass:[PlainTextWindowController class]]) {
		result = nil;
	}
	return result;
}

- (void)keyDown:(NSEvent *)aEvent {
    //    NSLog(@"aEvent: %@",[aEvent description]);
    int flags = [aEvent modifierFlags];

    if ((flags & NSControlKeyMask) &&
        !(flags & NSCommandKeyMask) &&
        [[aEvent characters] length] == 1)
    {
        NSString *characters = [aEvent characters];

        if ([characters isEqualToString:@"2"] &&
            self.topBarViewController.isVisible)
        {
            [self.topBarViewController keyboardActivateSymbolPopUp];
            return;
        }
        else if ([characters isEqualToString:@"1"])
        {
            static NSPopUpButtonCell *s_cell = nil;

            if (!s_cell)
            {
                s_cell = [NSPopUpButtonCell new];
                [s_cell setControlSize:NSSmallControlSize];
                [s_cell setFont:[NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSSmallControlSize]]];
            }

            [s_cell setMenu:[[SEEDocumentController sharedInstance] documentMenu]];
            NSEnumerator *menuItems = [[[s_cell menu] itemArray] objectEnumerator];
            NSMenuItem *menuItem  = nil;
            PlainTextWindowController *wc = [[I_textView window] windowController];
            NSArray *orderedDocuments = [wc orderedDocuments];
            PlainTextDocument *myDocument = [self document];

            while ((menuItem = [menuItems nextObject]))
            {
                if ([menuItem target] == wc &&
                    [[menuItem representedObject] intValue] == [orderedDocuments indexOfObject:myDocument])
                {
                    [s_cell selectItem:menuItem];
                    break;
                }
            }
            NSRect frame = [self.O_editorView frame];
            frame.size.width = 50;
            frame.origin.y = frame.size.height - 20;
            frame.size.height = 20;
            [s_cell performClickWithFrame:frame inView:self.O_editorView];
            return;
        }
        else if ([self showsBottomStatusBar])
        {
            if ([characters isEqualToString:@"3"])
            {
                [O_modePopUpButton performClick:self];
                return;
            }
            else if ([characters isEqualToString:@"4"])
            {
                [O_tabStatusPopUpButton performClick:self];
                return;
            }
            else if ([characters isEqualToString:@"5"])
            {
                [O_lineEndingPopUpButton performClick:self];
                return;
            }
            else if ([characters isEqualToString:@"6"])
            {
                [O_encodingPopUpButton performClick:self];
                return;
            }
            else if ([characters isEqualToString:@"7"])
            {
                [O_windowWidthTextField performClick:self];
                return;
            }
        }
        else
        {
            static NSSet *s_bottomShortCutSet = nil;

            if (!s_bottomShortCutSet)
            {
                s_bottomShortCutSet = [[NSSet alloc] initWithObjects:@"3", @"4", @"5", @"6", @"7", nil];
            }

            PlainTextEditor *otherEditor =
			[[I_windowControllerTabContext plainTextEditors] lastObject];

            if ([otherEditor showsBottomStatusBar] &&
                [s_bottomShortCutSet containsObject:characters])
            {
                [otherEditor keyDown:aEvent];
                return;
            }
        }
    }

    [super keyDown:aEvent];
}


#pragma mark ### position fixes for remote editing ###
- (void)storePosition
{
    // idea: get the character index of the character in the upper left of the window, store that, and for restore apply the operation and scroll that character back to the upper left line
    NSRect visibleRect = [O_scrollView documentVisibleRect];
    NSPoint point = visibleRect.origin;

    point.y += 1.;
    NSLayoutManager *layoutManager = [I_textView layoutManager];
    NSTextStorage *textStorage = [I_textView textStorage];

    if ([textStorage length])
    {
        unsigned glyphIndex = [layoutManager glyphIndexForPoint:point
												inTextContainer:[I_textView textContainer]];
        unsigned characterIndex = [layoutManager characterIndexForGlyphAtIndex:glyphIndex];
        [I_storedPosition release];
        I_storedPosition = [[SelectionOperation selectionOperationWithRange:NSMakeRange(characterIndex, 0) userID:@"doesn't matter"] retain];
    }
}


- (void)restorePositionAfterOperation:(TCMMMOperation *)aOperation
{
    if (I_storedPosition && [[I_textView string] length])
    {
        NSLayoutManager *layoutManager = [I_textView layoutManager];
        TCMMMTransformator *transformator = [TCMMMTransformator sharedInstance];
        [transformator transformOperation:I_storedPosition serverOperation:aOperation];
        unsigned glyphIndex = [layoutManager glyphRangeForCharacterRange:[I_storedPosition selectedRange] actualCharacterRange:NULL].location;
        NSRect boundingRect  = [layoutManager lineFragmentRectForGlyphAtIndex:glyphIndex
															   effectiveRange:nil];
        NSRect visibleRect = [O_scrollView documentVisibleRect];

        if (visibleRect.origin.y != boundingRect.origin.y)
        {
            visibleRect.origin.y = boundingRect.origin.y;
            [I_textView scrollRectToVisible:visibleRect];
            [[O_scrollView verticalRulerView] setNeedsDisplay:YES];
        }
    }
}


#pragma mark -
#pragma mark ### display fixes for bottom status bar pop up buttons ###
// proxy method for status bar encoding dropdown to reset state on selection
- (IBAction)showCustomizeEncodingPanel:(id)aSender {
    [self performSelector:@selector(TCM_updateBottomStatusBar) withObject:nil afterDelay:0.0001];
    [[EncodingManager sharedInstance] showWindow:aSender];
}


#pragma mark -
#pragma mark ### SEEFindAndReplaceViewController methods ###

- (void)findAndReplaceViewControllerDidPressDismiss:(SEEFindAndReplaceViewController *)aViewController {
	[self hideFindAndReplace:self];
}

#pragma mark -
#pragma mark ### NSTextView delegate methods ###

- (BOOL)textView:(NSTextView *)aTextView clickedOnLink:(id)link atIndex:(NSUInteger)charIndex
{
    NSRange selectedRange = [aTextView selectedRange];

    if (selectedRange.length > 0 && NSLocationInRange(charIndex, selectedRange))
    {
        // this was a context click and menu selection, instead of a real click, let the system handle that
        return NO;
    }
    else
    {
        [aTextView setSelectedRange:NSMakeRange(charIndex, 0)];

        URLBubbleWindow *bubbleWindow = [URLBubbleWindow sharedURLBubbleWindow];
        NSWindow *window = [aTextView window];
        [bubbleWindow setURLToOpen:link];

        // find out position of character:
        NSLayoutManager *layoutManager = [aTextView layoutManager];
        NSRange glyphRange = [layoutManager glyphRangeForCharacterRange:NSMakeRange(charIndex, 1) actualCharacterRange:NULL];
        NSTextContainer *container = [aTextView textContainer];
        NSRect boundingRect = [layoutManager boundingRectForGlyphRange:glyphRange inTextContainer:container];

        // transform the boundingRect from container coords to actual window coords
        NSPoint textContainerOrigin = [aTextView textContainerOrigin];
        boundingRect.origin.x += textContainerOrigin.x;
        boundingRect.origin.y += textContainerOrigin.y;

        NSPoint positionPoint = NSMakePoint(NSMidX(boundingRect), NSMinY(boundingRect));         // textviews are always flipped
        positionPoint = [aTextView convertPoint:positionPoint toView:nil];

        [bubbleWindow setVisible:NO animated:NO];
        [bubbleWindow setPosition:positionPoint inWindow:window];
        [bubbleWindow setVisible:YES animated:YES];
        return YES;
    }
}


- (NSString *)textView:(NSTextView *)inTextView willDisplayToolTip:(NSString *)inTooltip forCharacterAtIndex:(NSUInteger)inCharacterIndex
{
    FoldableTextStorage *ts = (FoldableTextStorage *)[inTextView textStorage];
    id attachment = [ts attribute:NSAttachmentAttributeName atIndex:inCharacterIndex effectiveRange:NULL];

    if (attachment)
    {
        NSHelpManager *hm = [NSHelpManager sharedHelpManager];
        NSAttributedString *helpString = [ts attributedStringOfFolding:attachment];
        NSLog(@"%s helpString", __FUNCTION__);
        [hm setContextHelp:helpString forObject:attachment];
        [hm showContextHelpForObject:attachment locationHint:[NSEvent mouseLocation]];
        [hm removeContextHelpForObject:attachment];
        return nil;
        //		return [ts foldedStringRepresentationOfRange:[attachment foldedTextRange] foldings:[attachment innerAttachments] level:1];
    }
    else
    {
        return inTooltip;
    }
}


- (void)textView:(NSTextView *)view doubleClickedOnCell:(id <NSTextAttachmentCell> )cell inRect:(NSRect)rect atIndex:(NSUInteger)inIndex
{
    if ([[cell attachment] isKindOfClass:[FoldedTextAttachment class]])
    {
        [(FoldableTextStorage *)[view textStorage] unfoldAttachment : (FoldedTextAttachment *)[cell attachment] atCharacterIndex : inIndex];
    }
}


- (NSArray *)textView:(NSTextView *)aTextView writablePasteboardTypesForCell:(id <NSTextAttachmentCell> )cell atIndex:(NSUInteger)charIndex
{
    if ([[cell attachment] isKindOfClass:[FoldedTextAttachment class]])
    {
        return [NSArray arrayWithObject:NSStringPboardType];
    }
    else
    {
        return nil;
    }
}


- (BOOL)textView:(NSTextView *)aTextView writeCell:(id <NSTextAttachmentCell> )cell atIndex:(NSUInteger)charIndex toPasteboard:(NSPasteboard *)pboard type:(NSString *)type
{
    id attachment = [cell attachment];

    if ([attachment isKindOfClass:[FoldedTextAttachment class]])
    {
        //		NSLog(@"%s type:%@",__FUNCTION__,type);
        FoldableTextStorage *ts = (FoldableTextStorage *)[aTextView textStorage];
        NSString *stringToPaste = [[[ts fullTextStorage] string] substringWithRange:[attachment foldedTextRange]];

        if (stringToPaste)
        {
            [pboard setString:stringToPaste forType:type];
            return YES;
        }
    }

    return NO;
}


- (void)textViewContextMenuNeedsUpdate:(NSMenu *)aContextMenu
{
    NSMenu *scriptMenu = [[aContextMenu itemWithTag:12345] submenu];

    [scriptMenu removeAllItems];
    PlainTextDocument *document = (PlainTextDocument *)[self document];
    [document fillScriptsIntoContextMenu:scriptMenu];

    if ([scriptMenu numberOfItems] == 0)
    {
        [[aContextMenu itemWithTag:12345] setEnabled:NO];
    }
    else
    {
        [[aContextMenu itemWithTag:12345] setEnabled:YES];
    }
}


- (BOOL)textView:(NSTextView *)aTextView doCommandBySelector:(SEL)aSelector
{
    //	NSLog(@"%s %@",__FUNCTION__,NSStringFromSelector(aSelector));
    if (aSelector == @selector(insertBacktab:) ||
        aSelector == @selector(insertTab:) ||
        aSelector == @selector(insertNewline:) ||
        aSelector == @selector(insertLineBreak:) ||
        aSelector == @selector(insertParagraphSeparator:) ||
        aSelector == @selector(insertTabIgnoringFieldEditor:) ||
        aSelector == @selector(insertNewlineIgnoringFieldEditor:))
    {
        [self scheduleTextCheckingForRange:[[[aTextView textStorage] string] lineRangeForRange:[aTextView selectedRange]]];
    }

    PlainTextDocument *document = (PlainTextDocument *)[self document];

    if (![document isRemotelyEditingTextStorage])
    {
        [self setFollowUserID:nil];
    }

    return [document textView:aTextView doCommandBySelector:aSelector];
}


- (BOOL)textView:(NSTextView *)aTextView shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString
{
    [[URLBubbleWindow sharedURLBubbleWindow] hideIfNecessary];
    if (replacementString == nil) return YES;     // only styles are changed

    PlainTextDocument *document = [self document];

    if (![document isRemotelyEditingTextStorage])
    {
        [self setFollowUserID:nil];
    }

    if (document && ![document isFileWritable] && ![document editAnyway])
    {
        NSDictionary *contextInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                     @"EditAnywayAlert", @"Alert",
                                     aTextView, @"TextView",
                                     [[replacementString copy] autorelease], @"ReplacementString",
                                     nil];

        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert setMessageText:NSLocalizedString(@"Warning", nil)];
        [alert setInformativeText:NSLocalizedString(@"File is read-only", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Edit anyway", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
        [[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
        [alert beginSheetModalForWindow:[aTextView window]
						 modalDelegate	:document
						didEndSelector	:@selector(alertDidEnd:returnCode:contextInfo:)
						  contextInfo		:[contextInfo retain]];

        return NO;
    }

    if (![replacementString canBeConvertedToEncoding:[document fileEncoding]] && ![aTextView hasMarkedText])
    {
        TCMMMSession *session = [document session];

        if ([session isServer] && [session participantCount] <= 1)
        {
            NSMutableDictionary *contextInfo = [[NSMutableDictionary alloc] init];
            [contextInfo setObject:@"ShouldPromoteAlert" forKey:@"Alert"];
            [contextInfo setObject:aTextView forKey:@"TextView"];
            [contextInfo setObject:[[replacementString copy] autorelease] forKey:@"ReplacementString"];
            [contextInfo setObject:[NSValue valueWithRange:affectedCharRange] forKey:@"AffectedCharRange"];
            [contextInfo autorelease];

            NSAlert *alert = [[[NSAlert alloc] init] autorelease];
            [alert setAlertStyle:NSWarningAlertStyle];
            [alert setMessageText:NSLocalizedString(@"You are trying to insert characters that cannot be handled by the file's current encoding. Do you want to cancel the change?", nil)];
            [alert setInformativeText:NSLocalizedString(@"You are no longer restricted by the file's current encoding if you promote to a Unicode encoding.", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Insert", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Promote to UTF8", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Promote to Unicode", nil)];
            [[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
            [alert beginSheetModalForWindow:[aTextView window]
							 modalDelegate	:document
                            didEndSelector	:@selector(alertDidEnd:returnCode:contextInfo:)
							  contextInfo		:[contextInfo retain]];
        }
        else
        {
            NSBeep();
        }

        return NO;
    }
    else
    {
        [aTextView setTypingAttributes:[(FoldableTextStorage *)[aTextView textStorage] attributeDictionaryByAddingStyleAttributesForInsertLocation : affectedCharRange.location toDictionary :[(PlainTextDocument *)[self document] typingAttributes]]];
    }

    [aTextView setTypingAttributes:[(FoldableTextStorage *)[aTextView textStorage] attributeDictionaryByAddingStyleAttributesForInsertLocation : affectedCharRange.location toDictionary :[(PlainTextDocument *)[self document] typingAttributes]]];

    if ([(SEETextView *)aTextView isPasting] && ![(FoldableTextStorage *)[aTextView textStorage] hasMixedLineEndings])
    {
        NSUInteger length = [replacementString length];
        NSUInteger curPos = 0;
        NSUInteger startIndex, endIndex, contentsEndIndex;
        NSString *lineEndingString = [document lineEndingString];
        NSUInteger lineEndingStringLength = [lineEndingString length];
        unichar *lineEndingBuffer = NSZoneMalloc(NULL, sizeof(unichar) * lineEndingStringLength);
        [lineEndingString getCharacters:lineEndingBuffer];
        BOOL isLineEndingValid = YES;

        while (curPos < length)
        {
            [replacementString getLineStart:&startIndex end:&endIndex contentsEnd:&contentsEndIndex forRange:NSMakeRange(curPos, 0)];

            if ((contentsEndIndex + lineEndingStringLength) <= length)
            {
                unsigned i;

                for (i = 0; i < lineEndingStringLength; i++)
                {
                    if ([replacementString characterAtIndex:contentsEndIndex + i] != lineEndingBuffer[i])
                    {
                        isLineEndingValid = NO;
                        break;
                    }
                }
            }

            curPos = endIndex;
        }

        NSZoneFree(NSZoneFromPointer(lineEndingBuffer), lineEndingBuffer);

        if (!isLineEndingValid)
        {
            NSMutableDictionary *contextInfo = [[NSMutableDictionary alloc] init];
            [contextInfo setObject:@"PasteWrongLineEndingsAlert" forKey:@"Alert"];
            [contextInfo setObject:aTextView forKey:@"TextView"];
            [contextInfo setObject:[[replacementString copy] autorelease] forKey:@"ReplacementString"];
            [contextInfo autorelease];

            NSAlert *alert = [[[NSAlert alloc] init] autorelease];
            [alert setAlertStyle:NSWarningAlertStyle];
            [alert setMessageText:NSLocalizedString(@"You are pasting text that does not match the file's current line endings. Do you want to paste the text with converted line endings?", nil)];
            [alert setInformativeText:NSLocalizedString(@"The file will have mixed line endings if you do not paste converted text.", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Paste Converted", nil)];
            [alert addButtonWithTitle:NSLocalizedString(@"Paste Unchanged", nil)];
            [[[alert buttons] objectAtIndex:0] setKeyEquivalent:@"\r"];
            [alert beginSheetModalForWindow:[aTextView window]
							 modalDelegate	:document
                            didEndSelector	:@selector(alertDidEnd:returnCode:contextInfo:)
							  contextInfo		:[contextInfo retain]];
            return NO;
        }
    }

    BOOL result = [document textView:aTextView shouldChangeTextInRange:affectedCharRange replacementString:replacementString];

    if (result)       // fix for textview not doing autocorrection - uses internal methods as savely as possible - #beware
    {
        if (affectedCharRange.length == 0 &&
            [replacementString length] == 1)
        {
            unichar character = [replacementString characterAtIndex:0];

            if (character == ' ' || character == 0x00a0 || character == '\t')
            {
                [self scheduleTextCheckingForRange:[[[aTextView textStorage] string] lineRangeForRange:affectedCharRange]];
            }
        }
    }

    return result;
}


- (void)scheduleTextCheckingForRange:(NSRange)aRange
{
    SEL selector = @selector(_scheduleTextCheckingForRange:);

    if ([I_textView respondsToSelector:selector])
    {
        objc_msgSend(I_textView, selector, aRange);
    }
}


- (void)setNeedsDisplayForRuler
{
    if ([O_scrollView rulersVisible])
    {
        NSRulerView *ruler = [O_scrollView verticalRulerView];
        [ruler setNeedsDisplayInRect:[ruler visibleRect]];
    }
}


- (void)textDidChange:(NSNotification *)aNotification
{
    [self setNeedsDisplayForRuler];
}


- (void)contentViewBoundsDidChange:(NSNotification *)aNotification
{
    [[URLBubbleWindow sharedURLBubbleWindow] hideIfNecessary];
    [self setNeedsDisplayForRuler];
}


- (NSRange) textView								:(NSTextView *)aTextView
willChangeSelectionFromCharacterRange	:(NSRange)aOldSelectedCharRange
	  toCharacterRange						:(NSRange)aNewSelectedCharRange
{
    [[URLBubbleWindow sharedURLBubbleWindow] hideIfNecessary];
    PlainTextDocument *document = (PlainTextDocument *)[self document];
    return [document textView:aTextView
willChangeSelectionFromCharacterRange	:aOldSelectedCharRange
	   toCharacterRange						:aNewSelectedCharRange];
}


- (void)textViewDidChangeSelection:(NSNotification *)aNotification
{
    if (I_flags.pausedProcessing)
    {
        I_flags.pausedProcessing = NO;
        [[[self document] session] startProcessing];
    }

	[self.topBarViewController updateForSelectionDidChange];
}


- (NSDictionary *)blockeditAttributesForTextView:(NSTextView *)aTextView
{
    return [[self document] blockeditAttributes];
}


- (void)textViewDidChangeSpellCheckingSetting:(SEETextView *)aTextView
{
    [[self document] takeSpellCheckingSettingsFromEditor:self];
}


- (void)textView:(NSTextView *)aTextView mouseDidGoDown:(NSEvent *)aEvent
{
    [self setFollowUserID:nil];

    if (!I_flags.pausedProcessing)
    {
        I_flags.pausedProcessing = YES;
        [[[self document] session] pauseProcessing];
    }
}


#pragma mark -

- (void)scrollToUserWithID:(NSString *)aUserID
{
    TCMMMUser *user = [[TCMMMUserManager sharedInstance] userForUserID:aUserID];

    if (user)
    {
        NSDictionary *sessionProperties = [user propertiesForSessionID:[[[self document] session] sessionID]];
        SelectionOperation *selectionOperation = [sessionProperties objectForKey:@"SelectionOperation"];

        if (selectionOperation)
        {
            [I_textView scrollFullRangeToVisible:[selectionOperation selectedRange]];
        }
    }
}


- (void)defaultParagraphStyleDidChange:(NSNotification *)aNotification
{
    [I_textView setDefaultParagraphStyle:[(PlainTextDocument *)[self document] defaultParagraphStyle]];
    [self TCM_updateBottomStatusBar];
    [self textDidChange:aNotification];
    [I_textView setNeedsDisplay:YES];
}


- (void)plainTextDocumentDidChangeEditStatus:(NSNotification *)aNotification
{
    if ([[self document] wrapLines] != [self wrapsLines])
    {
        [self setWrapsLines:[[self document] wrapLines]];
    }

    [self TCM_updateBottomStatusBar];
    [I_textView setNeedsDisplay:YES];     // because the change could have involved line endings
}


- (void)plainTextDocumentUserDidChangeSelection:(NSNotification *)aNotification
{
    NSString *followUserID = [self followUserID];

    if (followUserID)
    {
        if ([[[[aNotification userInfo] objectForKey:@"User"] userID] isEqualToString:followUserID])
        {
            [self scrollToUserWithID:followUserID];
        }
    }
}


#pragma mark -
#pragma mark ### notification handling ###

- (void)textViewFrameDidChange:(NSNotification *)aNotification
{
    [I_radarScroller setMaxHeight:[I_textView frame].size.height];
}


- (void)viewFrameDidChange:(NSNotification *)aNotification
{
    [self.topBarViewController adjustLayout];
    [self TCM_updateBottomStatusBar];
}


- (void)setRadarMarkForUser:(TCMMMUser *)aUser
{
    NSString *sessionID = [[[self document] session] sessionID];
    NSColor *changeColor = [aUser changeColor];

    SelectionOperation *selectionOperation = [[aUser propertiesForSessionID:sessionID] objectForKey:@"SelectionOperation"];

    if (selectionOperation)
    {
        NSUInteger rectCount;
        NSRange range = [selectionOperation selectedRange];
        NSLayoutManager *layoutManager = [I_textView layoutManager];

        if (layoutManager)
        {
            NSRectArray rects = [layoutManager
                                 rectArrayForCharacterRange:range
								 withinSelectedCharacterRange:range
								 inTextContainer				:[I_textView textContainer]
								 rectCount					:&rectCount];

            if (rectCount > 0)
            {
                NSRect rect = rects[0];
                unsigned i;

                for (i = 1; i < rectCount; i++)
                {
                    rect = NSUnionRect(rect, rects[i]);
                }

                [I_radarScroller setMarkFor:[aUser userID]
								withColor		:changeColor
							forMinLocation	:(float)rect.origin.y
							andMaxLocation	:(float)NSMaxY(rect)];
            }
        }
        else
        {
            NSLog(@"%s Textview:%@ has not yet a layoutmanager:%@ - strange document: %@", __FUNCTION__, I_textView, layoutManager, [[self document] displayName]);
        }
    }
    else
    {
        [I_radarScroller removeMarkFor:[aUser userID]];
    }
}


- (void)userDidChangeSelection:(NSNotification *)aNotification
{
    TCMMMUser *user = [[aNotification userInfo] objectForKey:@"User"];

    if (user)
    {
        [self setRadarMarkForUser:user];
    }
}


#pragma mark - State Restoration

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder {
//	NSLog(@"%s - %d : %@", __FUNCTION__, __LINE__, self.document.displayName);
	[super encodeRestorableStateWithCoder:coder];
}

- (void)restoreStateWithCoder:(NSCoder *)coder {
//	NSLog(@"%s - %d : %@", __FUNCTION__, __LINE__, self.document.displayName);
	[super restoreStateWithCoder:coder];
}

#pragma mark -
#pragma mark ### Auto completion ###

- (NSArray *)textView:(NSTextView *)textView completions:(NSArray *)words forPartialWordRange:(NSRange)charRange indexOfSelectedItem:(NSInteger *)index
{
    NSString *partialWord, *completionEntry;
    NSMutableArray *completions = [NSMutableArray array];
    unsigned i, count;
    NSString *textString = [[textView textStorage] string];

    // Get the current partial word being completed.
    partialWord = [textString substringWithRange:charRange];

    NSMutableDictionary *dictionaryOfResultStrings = [NSMutableDictionary new];

    // find all matches in the current text for this prefix
    PlainTextDocument *myDocument = [self document];
    DocumentMode *documentMode = [myDocument documentMode];

    NSEnumerator *matches = [myDocument matchEnumeratorForAutocompleteString:partialWord];
    OGRegularExpressionMatch *match = nil;

    while ((match = [matches nextObject]))
        [dictionaryOfResultStrings setObject:@"YES" forKey:[match matchedString]];
    [completions addObjectsFromArray:[[dictionaryOfResultStrings allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]];

    // Check if we should use a different mode than the default mode here.

    DocumentMode *theMode = documentMode;

    unsigned int characterIndex = charRange.location;
    unsigned int stringLength = [textString length];

    if (characterIndex < stringLength ||
        (characterIndex == stringLength && characterIndex > 0))
    {
        if (characterIndex == stringLength)
        {
            characterIndex--;
        }

        NSString *modeForAutocomplete = [[textView textStorage] attribute:kSyntaxHighlightingParentModeForAutocompleteAttributeName atIndex:characterIndex effectiveRange:NULL];

        if (modeForAutocomplete)
        {
            theMode = [[DocumentModeManager sharedInstance] documentModeForName:modeForAutocomplete];
        }
    }

    // Get autocompletions from mode responsible for the insert location.
    NSArray *completionSource = [theMode autocompleteDictionary];
    // Examine them one by one.
    count = [completionSource count];

    for (i = 0; i < count; i++)
    {
        completionEntry = [completionSource objectAtIndex:i];

        // Add those that match the current partial word to the list of completions.
        if ([completionEntry hasPrefix:partialWord] &&
            [dictionaryOfResultStrings objectForKey:completionEntry] == nil)
        {
            [completions addObject:completionEntry];
            [dictionaryOfResultStrings setObject:@"YES" forKey:completionEntry];
        }
    }

    // add suggestions from all other open documents
    NSMutableDictionary *otherDictionaryOfResultStrings = [NSMutableDictionary new];
    NSEnumerator *documents = [[[SEEDocumentController sharedInstance] documents] objectEnumerator];
    PlainTextDocument *document = nil;

    while ((document = [documents nextObject]))
    {
        if (document == myDocument) continue;

        NSEnumerator *matches = [document matchEnumeratorForAutocompleteString:partialWord];
        OGRegularExpressionMatch *match = nil;

        while ((match = [matches nextObject]))
            if ([dictionaryOfResultStrings objectForKey:[match matchedString]] == nil) [otherDictionaryOfResultStrings setObject:@"YES" forKey:[match matchedString]];

    }
    [completions addObjectsFromArray:[[otherDictionaryOfResultStrings allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]];
    [dictionaryOfResultStrings addEntriesFromDictionary:otherDictionaryOfResultStrings];

    // add the originally suggested words if spelling dictionary should be used
    if ([[documentMode syntaxDefinition] useSpellingDictionary])
    {
        id word;

        for (word in words)
        {
            if ([dictionaryOfResultStrings objectForKey:word] == nil) [completions addObject:word];

            [dictionaryOfResultStrings setObject:@"YES" forKey:word];
        }
    }

    //DEBUGLOG(@"SyntaxHighlighterDomain", DetailedLogLevel, @"Finished autocomplete");
    [dictionaryOfResultStrings release];
    [otherDictionaryOfResultStrings release];

    FullTextStorage *fts = [(FoldableTextStorage *)[I_textView textStorage] fullTextStorage];
    NSRange fullCharRange = [(FoldableTextStorage *)[I_textView textStorage] fullRangeForFoldedRange : charRange];
    NSString *autoend = [fts autoendForIndex:fullCharRange.location];

    if (autoend)
    {
        if (charRange.length == 0)
        {
            [completions insertObject:autoend atIndex:0];
        }
        else
        {
            NSRange matchRange = [autoend rangeOfString:partialWord];

            if (matchRange.location != NSNotFound)
            {
                // TODO: check text to the left of string as well
                BOOL shouldAdd = YES;

                if (matchRange.location > 0)
                {
                    shouldAdd = NO;

                    if (fullCharRange.location > matchRange.location && [[[fts string] substringWithRange:NSMakeRange(fullCharRange.location - matchRange.location, matchRange.location)] isEqualToString:[autoend substringToIndex:matchRange.location]])
                    {
                        shouldAdd = YES;
                    }
                }

                if (shouldAdd) [completions insertObject:[autoend substringFromIndex:matchRange.location] atIndex:0];
            }
        }
    }

    return completions;
}


- (void)textViewWillStartAutocomplete:(SEETextView *)aTextView
{
    //    NSLog(@"Start");
    PlainTextDocument *document = [self document];

    [document setIsHandlingUndoManually:YES];
    [document setShouldChangeChangeCount:NO];
}


- (void)textView:(SEETextView *)aTextView didFinishAutocompleteByInsertingCompletion:(NSString *)aWord forPartialWordRange:(NSRange)aCharRange movement:(int)aMovement
{
    //    NSLog(@"textView: didFinishAutocompleteByInsertingCompletion:%@ forPartialWordRange:%@ movement:%d",aWord,NSStringFromRange(aCharRange),aMovement);
    PlainTextDocument *document = [self document];
    UndoManager *undoManager = [document documentUndoManager];

    [undoManager registerUndoChangeTextInRange:NSMakeRange(aCharRange.location, [aWord length])
						 replacementString				:[[[aTextView textStorage] string] substringWithRange:aCharRange]
				shouldGroupWithPriorOperation	:NO];

    [document setIsHandlingUndoManually:NO];
    [document setShouldChangeChangeCount:YES];
    [document updateChangeCount:NSChangeDone];
}

@end


@implementation PlainTextEditor (PlainTextEditorScriptingAdditions)
- (id)scriptSelection
{
    return [ScriptTextSelection scriptTextSelectionWithTextStorage:[(FoldableTextStorage *)[[self textView] textStorage] fullTextStorage] editor:self];
}


- (void)setScriptSelection:(id)selection
{
    //NSLog(@"%s %@",__FUNCTION__,[selection debugDescription]);
    NSTextView *textView = [self textView];
    unsigned length = [[textView textStorage] length];

    if ([selection isKindOfClass:[NSArray class]] && [(NSArray *)selection count] == 2)
    {
        int startIndex = [[selection objectAtIndex:0] intValue];
        int endIndex = [[selection objectAtIndex:1] intValue];

        if (startIndex > 0 && startIndex <= length && endIndex >= startIndex && endIndex <= length) [textView setSelectedRange:NSMakeRange(startIndex - 1, endIndex - startIndex + 1)];
    }
    else if ([selection isKindOfClass:[NSNumber class]])
    {
        int insertionPointIndex = [selection intValue] - 1;
        insertionPointIndex = MAX(insertionPointIndex, 0);
        insertionPointIndex = MIN(insertionPointIndex, length);
        [textView setSelectedRange:NSMakeRange(insertionPointIndex, 0)];
    }
    else if ([selection isKindOfClass:[ScriptTextBase class]] || [selection isKindOfClass:[FoldableTextStorage class]])
    {
        NSRange newRange = RangeConfinedToRange([selection rangeRepresentation], NSMakeRange(0, length));
        [textView setSelectedRange:newRange];
    }
}

@end
