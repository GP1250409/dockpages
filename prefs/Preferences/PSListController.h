#import <UIKit/UIKit.h>
typedef NS_ENUM(NSInteger, PSCellType) { PSGroupCell, PSLinkCell, PSLinkListCell, PSListItemCell, PSTitleValueCell, PSSliderCell, PSSwitchCell, PSStaticTextCell, PSEditTextCell, PSSecureEditTextCell, PSButtonCell };
@interface PSSpecifier : NSObject {
@public
    SEL action;
}
@property (nonatomic, retain) NSString *name;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(PSCellType)cell edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end
@interface PSViewController : UIViewController
@end
@interface PSListController : PSViewController {
    NSArray *_specifiers;
}
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
@end
